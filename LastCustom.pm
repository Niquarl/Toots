# vim:set sw=4 ts=4 sts=4 ft=perl expandtab:
package LastCustom;
use Mojo::Base -strict;

sub custom_filter {
    my $content = shift;
    my $id      = shift;

    $content =~ s#Onoyo#Anoyo#g                                     if $id == 2583066;
    $content =~ s#il leur appris que#il leur apprit#                if $id == 2821837;
    $content =~ s#ne pas les avoir écouté#ne pas les avoir écoutés# if $id == 99050470493245348;
    $content =~ s#était prohibée#étaient prohibées#                 if $id == 99129348667201272;
    $content =~ s#<p></p>$##                                        if $id == 99998270052782061;
    $content =~ s#—_Si#— Si#                                        if $id == 100108605361094127;

    $content =~ s#« #« #g;
    $content =~ s# ([:!?»])# $1#g;

    return $content;
}

1;
