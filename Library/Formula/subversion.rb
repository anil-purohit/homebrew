require 'formula'

class Subversion < Formula
  homepage 'http://subversion.apache.org/'
  url 'http://archive.apache.org/dist/subversion/subversion-1.8.0.tar.bz2'
  # url 'http://www.apache.org/dyn/closer.cgi?path=subversion/subversion-1.8.0.tar.bz2'
  sha1 '45d227511507c5ed99e07f9d42677362c18b364c'

  bottle do
    revision 1
    sha1 '22b10c1758441a42b7c2273e8e25d4354db48574' => :mountain_lion
    sha1 'ecbfbc25e93fc1b2a4411dd64522903f21861ace' => :lion
    sha1 '03f81ee8f7fb8a518dfce74b32443ebbe6f812d8' => :snow_leopard
  end

  option :universal
  option 'java', 'Build Java bindings'
  option 'perl', 'Build Perl bindings'
  option 'ruby', 'Build Ruby bindings'

  depends_on 'pkg-config' => :build

  # Always build against Homebrew versions instead of system versions for consistency.
  depends_on 'serf'
  depends_on 'sqlite'
  depends_on :python => :optional

  # Building Ruby bindings requires libtool
  depends_on :libtool if build.include? 'ruby'

  # If building bindings, allow non-system interpreters
  env :userpaths if build.include? 'perl' or build.include? 'ruby'

  # One patch to prevent '-arch ppc' from being pulled in from Perl's $Config{ccflags},
  # and another one to put the svn-tools directory into libexec instead of bin
  def patches
    { :p0 => DATA }
  end

  # When building Perl or Ruby bindings, need to use a compiler that
  # recognizes GCC-style switches, since that's what the system languages
  # were compiled against.
  fails_with :clang do
    build 318
    cause "core.c:1: error: bad value (native) for -march= switch"
  end if build.include? 'perl' or build.include? 'ruby'

  def apr_bin
    Superenv.bin or "/usr/bin"
  end

  def install
    if build.include? 'unicode-path'
      raise Homebrew::InstallationError.new(self, <<-EOS.undent
        The --unicode-path patch is not supported on Subversion 1.8.

        Upgrading from a 1.7 version built with this patch is not supported.

        You should stay on 1.7, install 1.7 from homebrew-versions, or
          brew rm subversion && brew install subversion
        to build a new version of 1.8 without this patch.
      EOS
      )
    end

    if build.include? 'java'
      # Java support doesn't build correctly in parallel:
      # https://github.com/mxcl/homebrew/issues/20415
      ENV.deparallelize

      unless build.universal?
        opoo "A non-Universal Java build was requested."
        puts "To use Java bindings with various Java IDEs, you might need a universal build:"
        puts "  brew install subversion --universal --java"
      end

      ENV.fetch('JAVA_HOME') do
        opoo "JAVA_HOME is set. Try unsetting it if JNI headers cannot be found."
      end
    end

    ENV.universal_binary if build.universal?

    # Use existing system zlib
    # Use dep-provided other libraries
    # Don't mess with Apache modules (since we're not sudo)
    args = ["--disable-debug",
            "--prefix=#{prefix}",
            "--with-apr=#{apr_bin}",
            "--with-zlib=/usr",
            "--with-sqlite=#{Formula.factory('sqlite').opt_prefix}",
            "--with-serf=#{Formula.factory('serf').opt_prefix}",
            "--disable-mod-activation",
            "--disable-nls",
            "--without-apache-libexecdir",
            "--without-berkeley-db"]

    args << "--enable-javahl" << "--without-jikes" if build.include? 'java'

    if build.include? 'ruby'
      args << "--with-ruby-sitedir=#{lib}/ruby"
      # Peg to system Ruby
      args << "RUBY=/usr/bin/ruby"
    end

    # The system Python is built with llvm-gcc, so we override this
    # variable to prevent failures due to incompatible CFLAGS
    ENV['ac_cv_python_compile'] = ENV.cc

    system "./configure", *args
    system "make"
    system "make install"
    bash_completion.install 'tools/client-side/bash_completion' => 'subversion'

    system "make tools"
    system "make install-tools"

    python do
      system "make swig-py"
      system "make install-swig-py"
    end

    if build.include? 'perl'
      # Remove hard-coded ppc target, add appropriate ones
      if build.universal?
        arches = Hardware::CPU.universal_archs.as_arch_flags
      elsif MacOS.version <= :leopard
        arches = "-arch #{Hardware::CPU.arch_32_bit}"
      else
        arches = "-arch #{Hardware::CPU.arch_64_bit}"
      end

      perl_core = Pathname.new(`perl -MConfig -e 'print $Config{archlib}'`)+'CORE'
      unless perl_core.exist?
        onoe "perl CORE directory does not exist in '#{perl_core}'"
      end

      inreplace "Makefile" do |s|
        s.change_make_var! "SWIG_PL_INCLUDES",
          "$(SWIG_INCLUDES) #{arches} -g -pipe -fno-common -DPERL_DARWIN -fno-strict-aliasing -I/usr/local/include -I#{perl_core}"
      end
      system "make swig-pl"
      system "make", "install-swig-pl", "DESTDIR=#{prefix}"
    end

    if build.include? 'java'
      system "make javahl"
      system "make install-javahl"
    end

    if build.include? 'ruby'
      # Peg to system Ruby
      system "make swig-rb EXTRA_SWIG_LDFLAGS=-L/usr/lib"
      system "make install-swig-rb"
    end
  end

  def caveats
    s = <<-EOS.undent
      svntools have been installed to:
        #{opt_prefix}/libexec

    EOS

    s += python.standard_caveats if python

    if build.include? 'perl'
      s += <<-EOS.undent
        The perl bindings are located in various subdirectories of:
          #{prefix}/Library/Perl

      EOS
    end

    if build.include? 'ruby'
      s += <<-EOS.undent
        You may need to add the Ruby bindings to your RUBYLIB from:
          #{HOMEBREW_PREFIX}/lib/ruby

      EOS
    end

    if build.include? 'java'
      s += <<-EOS.undent
        You may need to link the Java bindings into the Java Extensions folder:
          sudo mkdir -p /Library/Java/Extensions
          sudo ln -s #{HOMEBREW_PREFIX}/lib/libsvnjavahl-1.dylib /Library/Java/Extensions/libsvnjavahl-1.dylib

      EOS
    end

    return s.empty? ? nil : s
  end
end

__END__
--- subversion/bindings/swig/perl/native/Makefile.PL.in~ 2013-06-20 18:58:55.000000000 +0200
+++ subversion/bindings/swig/perl/native/Makefile.PL.in	2013-06-20 19:00:49.000000000 +0200
@@ -69,10 +69,15 @@

 chomp $apr_shlib_path_var;

+my $config_ccflags = $Config{ccflags};
+# remove any -arch arguments, since those
+# we want will already be in $cflags
+$config_ccflags =~ s/-arch\s+\S+//g;
+
 my %config = (
     ABSTRACT => 'Perl bindings for Subversion',
     DEFINE => $cppflags,
-    CCFLAGS => join(' ', $cflags, $Config{ccflags}),
+    CCFLAGS => join(' ', $cflags, $config_ccflags),
     INC  => join(' ', $includes, $cppflags,
                  " -I$swig_srcdir/perl/libsvn_swig_perl",
                  " -I$svnlib_srcdir/include",

--- Makefile.in~ 2013-07-25 16:55:27.000000000 +0200
+++ Makefile.in 2013-07-25 17:02:02.000000000 +0200
@@ -85,7 +85,7 @@
 swig_pydir_extra = @libdir@/svn-python/svn
 swig_pldir = @libdir@/svn-perl
 swig_rbdir = $(SWIG_RB_SITE_ARCH_DIR)/svn/ext
-toolsdir = @bindir@/svn-tools
+toolsdir = @libexecdir@/svn-tools

 javahl_javadir = @libdir@/svn-javahl
 javahl_javahdir = @libdir@/svn-javahl/include
