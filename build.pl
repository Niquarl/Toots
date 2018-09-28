#!/usr/bin/perl
# vim:set sw=4 ts=4 sts=4 ft=perl expandtab:
use Mojo::Base -strict;
use Mojo::Collection 'c';
use Mojo::DOM;
use Mojo::File;
use Mojo::URL;
use Mojo::UserAgent;
use Mojo::Util qw(decode encode url_unescape);
use Mojo::JSON qw(decode_json encode_json);
use Mojolicious;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use DateTime;
use DateTime::Format::RFC3339;
use DateTime::Locale;
use File::Copy::Recursive qw(dircopy);
use File::Spec qw(catfile);
use File::Path qw(rmtree);
use FindBin qw($Bin);
use Text::Slugify 'slugify';
use XML::Atom::SimpleFeed;
use Pandoc;
use POSIX;

# Get config
my $m      = Mojolicious->new();
my $ua     = Mojo::UserAgent->new();
my $config = $m->plugin(Config => {
    file    => File::Spec->catfile($Bin, 'last.conf'),
    default => {
        theme    => 'default',
        sort     => 1,
        license  => '',
        markdown => 0,
    }
});
my $theme      = $config->{theme};

# Copy theme
rmtree("$Bin/public");
dircopy("$Bin/themes/$theme", "$Bin/public");

# Start to modify the index file
my $url     = Mojo::URL->new($config->{public_url});
my $file    = Mojo::File->new('public/index.html');
my $license = $config->{license};
my $index   = open_index();

## Atom feed
   $url  = Mojo::URL->new($config->{public_url});
my $iso  = DateTime::Format::RFC3339->format_datetime(DateTime->now());
my $feed = XML::Atom::SimpleFeed->new(
    title   => $config->{title},
    id      => $url->to_string,
    updated => $iso,
    author  => $config->{author},
    link    => {
        rel  => 'self',
        href => $url->path($url->path->merge('feed.atom'))->to_string
    },
    '-encoding' => 'utf-8'
);

## Epub
my $cover = Mojo::DOM->new(decode('UTF-8', Mojo::File->new('public/epub/OPS/cover.xhtml')->slurp));
$cover->find('title')
      ->first
      ->content($config->{title});
$cover->find('#header-title')
      ->first
      ->content($config->{title});
$cover->find('#author')
      ->first
      ->content($config->{author});
$cover->find('#license')
      ->first
      ->content($license);
Mojo::File->new('public/epub/OPS/cover.xhtml')->spurt(encode('UTF-8', $cover->to_string));

my $nav = Mojo::DOM->new(decode('UTF-8', Mojo::File->new('public/epub/OPS/nav.xhtml')->slurp));
$nav->find('html')
    ->first
    ->attr(lang       => $config->{language})
    ->attr('xml:lang' => $config->{language});
my $ol = $nav->find('ol')->first;

my $toc = Mojo::DOM->new(decode('UTF-8', Mojo::File->new('public/epub/OPS/toc.ncx')->slurp));
$toc->find('text')
    ->first
    ->content($config->{title});
my $navmap = $toc->find('navMap')->first;

my $opf = Mojo::DOM->new(decode('UTF-8', Mojo::File->new('public/epub/OPS/content.opf')->slurp));
$opf->find('#uuid_id')
    ->first
    ->content($url->to_string);
$opf->find('#dclanguage')
    ->first
    ->content($config->{language});
$opf->find('#dctitle')
    ->first
    ->content($config->{title});
$opf->find('#dccreator')
    ->first
    ->content($config->{author});
$opf->find('#dcdate')
    ->first
    ->content($iso);
$opf->find('meta[property="dcterms:modified"]')
    ->first
    ->content($iso);
my $manifest = $opf->find('manifest')->first;
my $spine    = $opf->find('spine')->first;

my $efile = Mojo::DOM->new(decode('UTF-8', Mojo::File->new('public/epub/content.xhtml')->slurp));
$efile->find('html')
      ->first
      ->attr(lang       => $config->{language})
      ->attr('xml:lang' => $config->{language});

## (re)Initialize variables
$url = Mojo::URL->new($config->{public_url});
my (@entries, @pages);
my $regex;
   $regex = join('|', @{$config->{hidden_tags}}) if $config->{hidden_tags};
### Pagination
my $pagination = $config->{pagination} || 0;
   $pagination = 0 unless $pagination > 0;
   $pagination = floor($pagination);
my $page       = 1;
### Where to insert the toots
my $c = $index->find('#content')->first;
$c->append_content("                    <p><a href=\"".slugify($config->{title}).".epub\">Epub</a></p>\n");
### Date formatting stuff
my $f = DateTime::Format::RFC3339->new();
my $l = DateTime::Locale->load($config->{language});
### Sort URLs
my $urls = c(@{$config->{urls}});
   $urls = $urls->sort(
    sub {
        my $a2 = $a;
        $a2 =~ s#^.*/([^/]+)$#$1#;
        my $b2 = $b;
        $b2 =~ s#^.*/([^/]+)$#$1#;
        $a2 <=> $b2
    }
) if $config->{sort};
   $urls  = $urls->reverse if $config->{reverse};
## Create needed dirs
mkdir 'public/epub/OPS/text';
mkdir 'cache' unless -e 'cache';

# URLs processing
my $n    = 0;
my %versions = ();
$urls->each(
    sub {
        my ($i, $num) = @_;

        ## Get the ID of the toot
        my $id = $i;
           $id =~ s#^.*/([^/]+)$#$1#;

        ## Get only the pod's hostname and scheme
        my $host = Mojo::URL->new($i)->path('');

        my $cache = (-e "cache/$id.json");

        my $msg   = "Processing $i";
           $msg  .= " from cache" if $cache;
        say $msg;

        my $res;
           $res = $ua->get($host->path("/api/v1/statuses/$id"))->result unless $cache;
        if ($cache || $res->is_success) {
            Mojo::File->new("cache/$id.json")->spurt(encode_json($res->json)) unless $cache;
            ## Get only the targeted toot, not the replies
            my $json    = ($cache) ? decode_json(Mojo::File->new("cache/$id.json")->slurp) : $res->json;
            ## Get the content of the toot
            my $content = Mojo::DOM->new($json->{content});
            ## Get the metadata (ie date and time) of the toot
            my $dt      = $f->parse_datetime($json->{created_at})->set_locale($config->{language});
            $dt->set_time_zone($config->{timezone}) if defined $config->{timezone};
            ## Get the attachments of the toot
            my $attach = c(@{$json->{media_attachments}});

            ## Remove style attribute
            ## Replace emoji with unicode characters
            $content->find('img.emojione')->each(
                sub {
                    my ($e, $num) = @_;
                    $e->replace($e->attr('alt'));
                }
            );
            ## Remove the configured hashtags
            $content->find('a.mention.hashtag')->each(
                sub {
                    my ($e, $num) = @_;
                    my $href = $e->attr('href');
                    $e->remove if $href =~ m#tags/($regex)$#;
                }
            ) if $regex;

            ## Format date and time
            my $date    = $dt->format_cldr($l->date_format_full);
            my $time    = $dt->format_cldr($l->time_format_medium);

            ## Store the attached images locally
            my @imgs;
            my @imgs2;
            $attach->each(
                sub {
                    my ($e, $inum) = @_;

                    my $src = $e->{url};
                       $src =~ s#\?(.*)##;
                    my $q   = $1;
                       $src =~ m#/([^/]*)$#;
                    my $n   = $1;
                       $src = Mojo::URL->new($src);

                    ## Attachments cache
                    my $acache = (-e "cache/img/$n" && -e "cache/img/$n.meta");
                    my $msg = sprintf("  Fetching image: %s", $src);
                       $msg .= " from cache" if $acache;
                    say $msg;

                    my $img = "img/$n";;
                    my $rmime;
                    if ($acache) {
                        # Get file metadata from cache
                        $rmime = decode_json(Mojo::File->new("cache/$img.meta")->slurp);
                        # Copy file
                        Mojo::File->new("cache/$img")->copy_to("public/$img")->copy_to("public/epub/OPS/$img");
                    } else {
                        my $r = $ua->get($src)->result;
                        if ($r->is_success) {
                            my $body = $r->body;
                              $rmime = $r->headers->content_type;

                            # Create cache
                            mkdir 'cache/img' unless -d 'cache/img';
                            Mojo::File->new("cache/$img")->spurt($body);
                            Mojo::File->new("cache/$img.meta")->spurt(encode_json($rmime));

                            # Copy file
                            Mojo::File->new("public/$img")->spurt($body);
                            Mojo::File->new("public/epub/OPS/$img")->spurt($body);
                        } elsif ($r->is_error) {
                            die sprintf("Error while fetching %s: %s", $src, $m->dumper($r->message));
                        }
                    }
                    if ($e->{type} eq 'image') {
                        push @imgs, "<img class=\"u-max-full-width\" src=\"$img\" alt=\"\">";
                    } elsif ($e->{type} eq 'video') {
                        push @imgs, "<video class=\"u-max-full-width\" src=\"$img\" alt=\"\"></video>";
                    }
                    if ($e->{type} eq 'image') {
                        push @imgs2, "<img class=\"u-max-full-width\" src=\"../$img\" alt=\"\" />";
                    } elsif ($e->{type} eq 'video') {
                        push @imgs2, "<video class=\"u-max-full-width\" src=\"../$img\" alt=\"\" ></video>";
                    }
                    $manifest->append_content("    <item id=\"i$num-$inum\" href=\"$img\" media-type=\"$rmime\" />\n");
                }
            );
            my $attachments  = (scalar @imgs)  ? "<div><p>@imgs</p></div>"  : '';
            my $attachments2 = (scalar @imgs2) ? "<div><p>@imgs2</p></div>" : '';

            ## Mix date, time, content and attachments
            # Modifs persos
            $content =~ s#Onoyo#Anoyo#g                      if $id == 2583066;
            $content =~ s#il leur appris que#il leur apprit# if $id == 2821837;
            $content =~ s#ne pas les avoir écouté#ne pas les avoir écoutés# if $id == 99050470493245348;
            $content =~ s#était prohibée#étaient prohibées# if $id == 99129348667201272;
            $content =~ s#« #« #g;
            $content =~ s# ([:!?»])# $1#g;
            if ($config->{markdown} && $content =~ m#([^%])?%md#) {
                $content =~ s#%%md#%%LAST_MARKDOWN%%#g;
                $content =~ s#%md##g;
                $content =~ s#%%LAST_MARKDOWN%%#%md#g;
                # Images
                $content =~ s#!\[(.*?)\]\(<a href="([^"]*)".*?</a>\)#![$1]($2)#gm;
                # Links with text
                $content =~ s#\[(.*?)\]\(<a href="([^"]*)".*?</a>\)#[$1]($2)#gm;
                # Links
                $content =~ s#&lt;<a href="([^"]*)".*?</a>&gt;#<$1>#gm;
                my $md;
                my $html = encode('UTF-8', $content);
                pandoc -f => 'markdown', -t => 'html', { in => \$html, out => \$md };
                say $md;
                $content = decode('UTF-8', $md);
            }
            $content =~ s#<p></p>|</br>##g;
            $content =~ s#<br>#<br />#g;
            my $append = "\n                    <article><a href=\"#$id\"><h3 id=\"$id\">$date <span style=\"font-size: 0.5em;\">$time</span></h3></a>$content$attachments<div><a href=\"$i\"><em>Source</em></a></div></article><hr>\n";

            ## Insert the toot
            $c->append_content($append);
            ## Paginate
            if ($pagination && (($num % $pagination) == 0 || ($num == $urls->size))) {
                my $prec = ($page == 2) ? 'index' : 'page'.($page - 1);

                if ($num == $urls->size) {
                    $c->append_content("\n                    <p class=\"u-pull-left\"><a class=\"button button-primary\" href=\"$prec.html\">⇐ Page précédente</a></p>");
                } else {
                    $page++;
                    if ($page == 2) {
                        $c->append_content("\n                    <p class=\"u-pull-right\"><a class=\"button button-primary\" href=\"page$page.html\">Page suivante ⇒</a></p>");
                    } else {
                        $c->append_content("\n                    <p class=\"u-pull-left\"><a class=\"button button-primary\" href=\"$prec.html\">⇐ Page précédente</a></p><p class=\"u-pull-right\"><a class=\"button button-primary\" href=\"page$page.html\">Page suivante ⇒</a></p>");
                    }
                    $c->append_content("               ");

                    $file->spurt(encode('UTF-8', $index));

                    $file  = Mojo::File->new("public/page$page.html");
                    $index = open_index();
                    $c     = $index->find('#content')->first;
                    $c->append_content("                    <p><a href=\"".slugify($config->{title}).".epub\">Epub</a></p>\n");
                }
            }

            ## Create entries for the atom feed
            push @entries, {
                title   => "$date $time",
                id      => "$url#$id",
                updated => DateTime::Format::RFC3339->format_datetime($dt),
                content => $append
            };

            ## Epub
            push @pages, {
                num     => $num,
                date    => $date,
                time    => $time,
                content => "<h1>$date <span style=\"font-size: 0.5em;\">$time</span></h1><hr/>$content$attachments2<div><a href=\"$i\"><em>Source</em></a></div>"
            };
        } elsif ($res->is_error) {
            die "Error while fetching $i: $res->message";
        }
    }
);
$c->append_content("               ");

# Write the index.html file
$file->spurt(encode('UTF-8', $index));

# Add entries in the atom feed
my $en = c(@entries);
   $en = $en->reverse unless $config->{reverse};
my $max = ($en->size < 20) ? $en->size -1 : 19;
   $en = $en->slice(0 .. $max);
$en->each(
    sub {
        my ($e, $num) = @_;
        $feed->add_entry(
            title   => $e->{title},
            id      => $e->{id},
            updated => $e->{updated},
            content => $e->{content},
        );
    }
);
## Write the atom feed
Mojo::File->new('public/feed.atom')->spurt($feed->as_string);

# Write the epub files
my $pa = c(@pages);
   $pa = $pa->reverse if $config->{reverse};
$pa->each(
    sub {
        my ($e, $num) = @_;
        my $date    = $e->{date};
        my $time    = $e->{time};
        my $content = $e->{content};
        my $tmp     = $efile;

        $tmp->find('.column')
              ->first
              ->content($content);
        $tmp->find('title')
              ->first
              ->content("$date $time");
        Mojo::File->new("public/epub/OPS/text/$num.xhtml")->spurt(encode('UTF-8', $tmp->to_string));

        $manifest->append_content("    <item id=\"t$num\" href=\"text/$num.xhtml\" media-type=\"application/xhtml+xml\" />\n");
        $spine->append_content("    <itemref idref=\"t$num\" />\n");
        $navmap->append_content("    <navPoint id=\"NavPoint-$num\" playOrder=\"$num\"><navLabel><text>$date $time</text></navLabel><content src=\"text/$num.xhtml\"/></navPoint>\n");
        $ol->append_content("\n                <li><a href=\"text/$num.xhtml\">$date $time</a></li>");
    }
);
my $num = $pa->size + 1;
$manifest->append_content("  ");
$spine->append_content("    <itemref idref=\"nav\" />\n  ");
$navmap->append_content("    <navPoint id=\"NavPoint-$num\" playOrder=\"$num\"><navLabel><text>Table des matières</text></navLabel><content src=\"nav.xhtml\"/></navPoint>\n");
$ol->append_content("\n                <li><a href=\"nav.xhtml\">Table des matières</a></li>\n            ");
Mojo::File->new('public/epub/OPS/toc.ncx')->spurt(encode('UTF-8', $toc->to_string));
Mojo::File->new('public/epub/OPS/nav.xhtml')->spurt(encode('UTF-8', $nav->to_string));
Mojo::File->new('public/epub/OPS/content.opf')->spurt(encode('UTF-8', $opf->to_string));

my $zip = Archive::Zip->new();
$zip->addFile('public/epub/mimetype', 'mimetype');
$zip->addTree('public/epub/OPS/', 'OPS');
$zip->addTree('public/epub/META-INF', 'META-INF');

unless ($zip->writeToFileNamed('public/'.slugify($config->{title}).'.epub') == AZ_OK) {
    die 'write error';
}
rmtree('public/epub') unless $ENV{LAST_DEBUG};

sub open_index {
    my $file   = Mojo::File->new("$Bin/themes/$theme/index.html");
    my $index  = Mojo::DOM->new(decode('UTF-8', $file->slurp));
    $index->find('html')
          ->first
          ->attr(lang => $config->{language});
    $index->find('title')
          ->first
          ->content($config->{title});
    $index->find('meta[name="author"]')
          ->first
          ->attr(content => $config->{author});
    $index->find('link[rel="alternate"]')
          ->first
          ->attr(href => $url->path($url->path->merge('feed.atom'))->to_string);
    $index->find('#header-title')
          ->first
          ->content($config->{title});
    $index->find('#author')
          ->first
          ->content($config->{author});
    if ($license) {
        $license = "<img alt=\"$license\" src=\"img/$license.png\">" if ($license eq 'cc-0');
        $license = "<img alt=\"$license\" src=\"img/$license.png\">" if ($license eq 'public-domain');
        $license = "<a rel=\"license\" href=\"http://creativecommons.org/licenses/by-nc-nd/4.0/\"><img alt=\"$license\" src=\"img/$license.png\"></a>" if ($license eq 'cc-by-nc-nd');
        $license = "<a rel=\"license\" href=\"http://creativecommons.org/licenses/by-nc-sa/4.0/\"><img alt=\"$license\" src=\"img/$license.png\"></a>" if ($license eq 'cc-by-nc-sa');
        $license = "<a rel=\"license\" href=\"https://creativecommons.org/licenses/by-nd/4.0/\"><img alt=\"$license\" src=\"img/$license.png\"></a>"   if ($license eq 'cc-by-nd');
        $license = "<a rel=\"license\" href=\"https://creativecommons.org/licenses/by/4.0/\"><img alt=\"$license\" src=\"img/$license.png\"></a>"      if ($license eq 'cc-by');
        $license = "<a rel=\"license\" href=\"https://creativecommons.org/licenses/by-sa/4.0/\"><img alt=\"$license\" src=\"img/$license.png\"></a>"   if ($license eq 'cc-by-sa');

        $index->find('#license')
              ->first
              ->content($license);
    } else {
        $index->find('#license')
              ->first
              ->remove;
    }

    return $index;
}
