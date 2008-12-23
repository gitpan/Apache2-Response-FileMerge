package Apache2::Response::FileMerge;

use strict;
use warnings;

use POSIX                qw( strftime mktime );
use APR::Table           ();
use Apache2::RequestUtil ();
use Apache2::Log         ();
use Apache2::RequestRec  ();
use Apache2::RequestIO   ();
use Apache2::Const       -compile => qw( OK HTTP_NOT_MODIFIED NOT_FOUND ); 

use constant {
    LAST_MODIFIED         => 'Last-Modified',
    MODIFIED_SINCE        => 'If-Modified-Since',
    LAST_MODIFIED_PATTERN => '%a, %b %e %Y %H:%M:%S PST',
    DIR_ACTIONS           => [ qw( minimize cache compress stats ) ],
    STATS_PATTERN         => '
/*
         URI: %s
       mtime: %s
       Cache: %s
   Minify JS: %s
  Minify CSS: %s
    Compress: %s
      Render: %s
*/
%s',
};

BEGIN {
    our $VERSION = join( '.', 0, ( '$Revision: 27 $' =~ /(\d+)/g ) );
};

my ( $i, $x )       = ( 0, 0 );
my $LOG             = undef;
my $DO_MIN_JS       = 0;
my $DO_MIN_CSS      = 0;
my $DO_MODIFIED     = 0;
my $DO_COMPRESS     = 0;
my $DO_STATS        = 0;
my %CONTENT_TYPES   = ( 'js'=> 'text/javascript', 'css' => 'text/css', );
my %NUMERICAL_MONTH = map{ $_ => $i++ } qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %NUMERICAL_DAY   = map{ $_ => $x++ } qw(Mon Tue Wed Thu Fri Sat Sun);

{
    my %cache;
    my $mtime = 0;
    sub handler {
        my $start = _time();
        _init();
        my ($r) = @_;
        $LOG    = $r->log();
        my $uri = $r->uri();

        # Undocumented as it's not the most efficient way of doing
        # things, but still here if/when needed (ie. unit tests)
        __PACKAGE__->$_() for ( grep{ $r->dir_config->get($_) } @{ DIR_ACTIONS() } );

        if ( $DO_MODIFIED ) {
            if ( my $modified = $r->headers_in()->{MODIFIED_SINCE()} ) {
                # Sat, Dec 20 2008 4:48:03
                my ( @time_parts, undef ) = split( /,?[\s:]/, $modified );
                my @o = @time_parts;
                $time_parts[0] = $NUMERICAL_DAY{$time_parts[0]};
                $time_parts[1] = $NUMERICAL_MONTH{$time_parts[1]}; 
                $time_parts[3] -= 1900;

                return Apache2::Const::HTTP_NOT_MODIFIED if (
                    $cache{$uri}{'mtime'}
                    && $cache{$uri}{'mtime'} <= mktime( map{$time_parts[$_]}qw( 6 5 4 2 1 3 ) )
                );
            }
        }

        my $content = '';
        my $type    = '';

        my ( $location, $file );
        ( $location, $file, $type ) = $uri =~ /^(.*)\/(.*)\.(js|css)$/;
        my $root                    = $r->document_root();

        foreach my $input ( split( '-', $file ) ) {
            $input     =~ s/\./\//g;
            $content  .= ( _load_content( $root, $location, $input, $type ) || '' );
        }

        my $has_content = ! ! $content;

        {
            no strict 'refs';
            $content  = &{ "_minimize_$type" }( 'input' => $content ) if ( $DO_MIN_JS || $DO_MIN_CSS );
        }
        my $delta = _time() - $start;
        $content  = sprintf(
            STATS_PATTERN,
            $uri,
            $mtime,
            $DO_MODIFIED,
            $DO_MIN_JS,
            $DO_MIN_CSS,
            $DO_COMPRESS,
            $delta,
            $content
        ) if ( $DO_STATS );

        $r->content_type( $CONTENT_TYPES{$type} || 'text/plain' );
        my $headers                 = $r->headers_out();
        $headers->{LAST_MODIFIED()} = strftime( LAST_MODIFIED_PATTERN, localtime( $mtime || 0 ) );
        $cache{$uri}{'mtime'}       = $mtime;
        
        if ( $DO_COMPRESS ) {
            $r->content_encoding('gzip');
            $content = _compress($content);
        }

        $r->print($content);

        return ( $has_content ) ? Apache2::Const::OK 
                                : Apache2::Const::NOT_FOUND;
    }

    {
        my %loaded;
        sub _init {
            %loaded = ();
        }

        sub _load_content {
            my ( $root, $location, $file_name, $type ) = @_;

            $LOG->debug( "\$location = $location" );
            $location =~ s/\/$//g;
            $location = "$location/";
            $LOG->debug( "\$location = $location" );

            $file_name       =  "${location}${file_name}" if ( $location );
            $file_name       =  "$root/$file_name.$type";
            my $cname        =  $file_name;
            $cname           =~ s/\///g;
            my $this_mtime   =  ( stat($file_name) )[9];
            $mtime         ||= 0;
            $mtime           =  $this_mtime if ( ! $mtime || $mtime > ( $this_mtime || 0 ) );
            my $content      =  '';

            if ( exists( $loaded{$cname} ) ) {
                $LOG->warn("Attempting to include \"$file_name\" more than once");
                return;
            }
            else {
                $loaded{$cname} = \0;
                $LOG->debug("Loading: $file_name");        
            }

            if ( open( my $handle, '<', $file_name ) ) {
                {
                    local $/ = undef;
                    $content = <$handle>;
                }
                close( $handle );
            }
            else {
                $LOG->error("File not found: $file_name");
                return;
            }

            $content = _sf_escape($content);
            while ( $content =~ /(\/\\\*\\\*\s*[Ii]nc(?:lude)\s*([\w\.\/]+)\s*\\\*\\\*\/)/sgm ) {
                my ( $matcher, $file )      =  ( $1, $2 );
                my ( $inc_file, $inc_type ) =  $file =~ /^(.*?)\.(js|css)$/;
                my $new_file_content        =  _load_content( $root, '', $inc_file, $inc_type ) || '';
                $content                    =~ s/\/\\\*\\\*\s*[Ii]nc(?:lude)\s*[\w\.\/]+\s*\\\*\\\*\//$new_file_content/sm;
            }

            return _sf_unescape($content);
        }
    }
}

sub cache {
    return $DO_MODIFIED ||= ! ! 1;
}

sub stats {
    $DO_STATS = ! ! 1;

    $DO_STATS = _register_function(
        'Time::HiRes',
        '_time',
        \&Time::HiRes::time
    );

    return $DO_STATS;
}

sub minimize {
    $DO_MIN_JS  = ! ! 1;
    $DO_MIN_CSS = ! ! 1;

    $DO_MIN_JS = _register_function(
        'JavaScript::Minifier',
        '_minimize_js',
        \&JavaScript::Minifier::minify
    );

    $DO_MIN_CSS = _register_function(
        'CSS::Minifier',
        '_minimize_css',
        \&CSS::Minifier::minify
    );

    return $DO_MIN_JS || $DO_MIN_CSS;
}

sub compress {
    $DO_COMPRESS = ! ! 1;

    $DO_COMPRESS = _register_function(
        'Compress::Zlib',
        '_compress',
        \&Compress::Zlib::memGzip
    );

    return $DO_COMPRESS;
}

sub _sf_escape {
    my ($escaper) = @_; 
    $escaper =~ s/\*/\\*/g;
    return $escaper;
}

sub _sf_unescape {
    my ($escaper) = @_;
    $escaper =~ s/\\\*/\*/g;
    return $escaper;
}

sub _register_function {
    my ( $class, $func, $ref ) = @_;

    eval {
        eval("use $class ();");
        if ( my $e = $@ ) {
            print STDERR "\"$class\" not installed, cannot use\n";
            return ! ! 0;
        }
        else {
            {
                no strict 'refs';
                no warnings 'redefine';
                *{$func} = $ref;
            }
            return ! ! 1;
        }
    }
}

sub _minimize_js  { return pop; }
sub _minimize_css { return pop; }
sub _compress($)  { return pop; }
sub _time()       { return 0;   }

1;

__END__

=head1 NAME

Apache2::Response::FileMerge - Merge and include static files into a single file

=head1 SYNOPSIS

L<Apache2::Response::FileMerge> gives you the ability to merge, include, minimize
and compress multiple js/css fles of a single type into a single file to place anywhere
into an HTTP document, all encapsulated into a single mod_perl Response handler.

=head1 DESCRIPTION

=head2 Problem(s) Solved

There are a number of best practices on how to generate content into a web page.
Yahoo!, for example, publishes such a document (http://developer.yahoo.com/performance/rules.html)
and is relatively well respected as it contains a number of good and useful tips 
for high-performance sites along with sites that are less strained but are still
trying to conserve the resources they have.  The basis of this module will contribute
to the resolution of three of these points and one that is not documented there.

=over

=item File Merging

A common problem with the standard development of sites is the number of <script/>,
<style/> and other static file includes that may/must be made in a single page.
Each requiring time, connections... overhead.  Although this isn't a revolutionary
solution, it is in terms of simple mod_perl handlers that can easily be integrated
into a single site.  Look to 'URI PROTOCOL' to see how this module will let you
programaticlly merge multiple files into a single file, allowing you to drop from
'n' <s(?:cript|style)> tags to a single file (per respective type).

=item File Minimization

A feature that can be administered programatically (see ATTRIBUTES), will minimize
whitespace usage for all CSS/Javascript files that leave the server.

=item File Compression

A feature that can be administered programatically (see ATTRIBUTES), will gzip 
the content before leaving the server.  Now, I can't ever imagine the need to
apply compression to a style or script file without wanting to apply it to /all/
content.  That said, I recommend the use of mod_gzip (L<http://sourceforge.net/projects/mod-gzip/>) 
rather than this attribute.  Still, I wanted to implement it, so I did.

=item C-Style Inlcudes

Merging files through a URI protocol is useful, however if you have a large-scale
application written in javascript, you quickly introduce namespacing, class
heirarchies and countless dependancies and files.  That said, it's tough to ask
a developer "List all the dependancies this class has, taking each of it's 
super-classes and encapsualted heirarchies into consideration".  Most modern
languages take care of this by allowing the developer to include it's particular
dependancies in the application code in it's particular file.  That said, this
module lets you do the same thing with CSS and Javascript.

As an example:

    /**
     * foo/bar.js
     * @inherits foo.js
     **/

     // Rather tha including foo.js as it's required by foo/bar.js,
     // simply include it directly in the file with the following
     // syntax:

     /** Include foo.js **/
     Foo.Bar = {};
     Foo.Bar.prototype = Foo;

Where, with that example, the file 'foo.js' will be a physical replacement
of the include statement and therefore will no longer need to be added to 
the URI.

=back

=head1 ATTRIBUTES

=over

=item cache

    Apache2::Response::FileMerge->cache();

Will enable HTTP 304 return codes, respecting the If-Modified-Since
keyword and therefore preventing the overhead of scraping through 
files again.

Given the nature of the module, the mtime of the requested document
will be the newest mtime of all the combined documents.

Furthermore, the server will only find the mtime of a collection of
documents when it reads the disk for the content.  Therfore, when 
enabled, any changes to the underlying files will also require
a reload/graceful of the server to pick up the changes and discontinue
the 304 return for the particular URI.

=item stats

    Apache2::Response::FileMerge->stats();

Will include statictics (pre-minimization) in a valid comment section
at the top of the document.  Something like the following can be expected:

    /*
             URI: /js/foo.bar-bar.baz.js
           mtime: 1229843477
           Cache: 1
        Minimize: 0
        Compress: 0
          Render: 0.0628039836883545
    */

=item minimize
    
    Apache2::Response::FileMerge->minimize();

Will use <JavaScript::Minifier> to minimize the Javascript and
L<CSS::Minifier> to minimize CSS, if installed.

=item compress 

    Apache2::Response::FileMerge->compress();

Will use <Compress::Zlib> to compress the document, if installed.

=back

=head1 EXAMPLES

=head2 httpd.conf

If all you want is the URI protocol and C-style includes, 
this is all you have to do:

    # httpd.conf
    <LocationMatch "\.js$">
        SetHandler perl-script
        PerlResponseHandler Apache2::Response::FileMerge
    </LocationMatch>

=head2 C-Style includes

This can be applied to either CSS or JS at any point in your document.
The moduel will implicitly trust the developer and therefore must be
syntaxually correct in all cases.  The handler will inject the code
of the included file into it's literal location.

The include will be respective of the DocumentRoot of the server.

Note the double-asterisks ('**') comment to indicate the include.

The 'Include' keyword is required (but can be replaced with 'Inc' if
you're lazy like me).

    /** Include foo/bar/baz.js **/

    /** Include foo/bar/baz.css **/

In all cases, the intent is that any file that is consumed by this module
can also be rendered and executed without this module, which is the point
behind the commented include structure.

=head2 URI Protocol

The URI will also allow you to include files.  The URI will include files
in the exact order they are listed, from left to right.  Furthermore, if a
URI that is requested is already included in a dependant file, the handler
will only include the first instance of the file (which will generally be
the first Include point).

The URI will be respective of directory location relative to the 
DocumentRoot.

'.' implies directory traversal.

'-' implies file seperation.

    # File foo/bar.js will be loaded, which is in the '/js/' directory
    http://...com/js/foo.bar.js

    # Will do the same as above, but makes less sense IMHO
    http://...com/js.foo.bar.js

    # File foo/bar.js will be loaded, which is in the document root
    http://...com/foo.bar.js

    # Will include foo.js and foo/bar.js respectively
    http://...com/foo-foo.bar.js

=head1 URI PROTOCOL

The generall usefulness of the advanced URI protocol is to combine 
files that are seemingly not dependant upon one another.  See
the EXAMPLES section for more details on this.

=head1 KNOWN ISSUES

=over

=item mod_perl v1.x

This will only work as a mod_perl 2.x PerlResponseHandler.  If there
is demand for 1.x, I will take the time to dynamically figure out 
what the right moduels, API, etc to use will be.  For now, being that
/I/ only use mod_perl 2.x, I have decided to not be overly clumsy 
with the code to take into consideration a platform people may not use.

=item CPAN shell installation

The unit tests each require L<Apache::Test> to run.  Yet, there are a
lot of conditions that would prevent you from actually having mod_perl
installed on a system of which you are trying to install this module.
Although I don't really see the need or think it's good practice to
install Apache2 namespaced modules without mod_perl, I have not made
Apache::Test a prerequisite of this module for the case I mentioned
earlier.  That said, no unit tests will pass without mod_perl already
installed and therefore will require a force install if that is what
you would like.  If that method is preferred, it is always possible
to re-test the module via the CPAN shell once mod_perl is installed.

At the time of this writing, L<Apache::Test> is included with the
mod_perl 2.x distribution.

=back

=head1 SEE ALSO

=over

=item L<Compress::Zlib>

=item L<JavaScript::Minifier>

=item L<CSS::Minifier>

=back

=head1 AUTHOR

Trevor Hall, E<lt>wazzuteke@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2009 by Trevor Hall

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


