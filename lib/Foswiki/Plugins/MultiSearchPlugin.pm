# See bottom of file for default license and copyright information

=begin TML

---+ package Foswiki::Plugins::MultiSearchPlugin

This plugin enables to perform multiple searches in one efficient macro.
It is an efficient way to build up tables of information that would otherwise
require multiple repeated SEARCH macros.

=cut

# change the package name!!!
package Foswiki::Plugins::MultiSearchPlugin;

# Always use strict to enforce variable scoping
use strict;
use warnings;

use Foswiki::Func    ();    # The plugins API
use Foswiki::Plugins ();    # For the API version
use Time::Local      ();
use Foswiki::Time    ();
use Time::ParseDate  ();    # For relative dates
use Data::Dumper;

# $VERSION is referred to by Foswiki, and is the only global variable that
# *must* exist in this package. For best compatibility, the simple quoted decimal
# version '1.00' is preferred over the triplet form 'v1.0.0'.

# For triplet format, The v prefix is required, along with "use version".
# These statements MUST be on the same line.
#  use version; our $VERSION = 'v1.2.3_001';
# See "perldoc version" for more information on version strings.
#
# Note:  Alpha versions compare as numerically lower than the non-alpha version
# so the versions in ascending order are:
#   v1.2.1_001 -> v1.2.2 -> v1.2.2_001 -> v1.2.3
#   1.21_001 -> 1.22 -> 1.22_001 -> 1.23
#
our $VERSION = '1.00';

# $RELEASE is used in the "Find More Extensions" automation in configure.
# It is a manually maintained string used to identify functionality steps.
# You can use any of the following formats:
# tuple   - a sequence of integers separated by . e.g. 1.2.3. The numbers
#           usually refer to major.minor.patch release or similar. You can
#           use as many numbers as you like e.g. '1' or '1.2.3.4.5'.
# isodate - a date in ISO8601 format e.g. 2009-08-07
# date    - a date in 1 Jun 2009 format. Three letter English month names only.
# Note: it's important that this string is exactly the same in the extension
# topic - if you use %$RELEASE% with BuildContrib this is done automatically.
# It is preferred to keep this compatible with $VERSION. At some future
# date, Foswiki will deprecate RELEASE and use the VERSION string.
#
our $RELEASE = '12 Aug 2015';

# One line description of the module
our $SHORTDESCRIPTION =
  'Perform multiple searches with one single efficient macro';

# You must set $NO_PREFS_IN_TOPIC to 0 if you want your plugin to use
# preferences set in the plugin topic. This is required for compatibility
# with older plugins, but imposes a significant performance penalty, and
# is not recommended. Instead, leave $NO_PREFS_IN_TOPIC at 1 and use
# =$Foswiki::cfg= entries, or if you want the users
# to be able to change settings, then use standard Foswiki preferences that
# can be defined in your %USERSWEB%.%LOCALSITEPREFS% and overridden at the web
# and topic level.
#
# %SYSTEMWEB%.DevelopingPlugins has details of how to define =$Foswiki::cfg=
# entries so they can be used with =configure=.
our $NO_PREFS_IN_TOPIC = 1;

=begin TML

---++ initPlugin($topic, $web, $user) -> $boolean
   * =$topic= - the name of the topic in the current CGI query
   * =$web= - the name of the web in the current CGI query
   * =$user= - the login name of the user
   * =$installWeb= - the name of the web the plugin topic is in
     (usually the same as =$Foswiki::cfg{SystemWebName}=)

*REQUIRED*

Called to initialise the plugin. If everything is OK, should return
a non-zero value. On non-fatal failure, should write a message
using =Foswiki::Func::writeWarning= and return 0. In this case
%<nop>FAILEDPLUGINS% will indicate which plugins failed.

In the case of a catastrophic failure that will prevent the whole
installation from working safely, this handler may use 'die', which
will be trapped and reported in the browser.

=cut

sub initPlugin {
    my ( $topic, $web, $user, $installWeb ) = @_;

    # check for Plugins.pm versions
    if ( $Foswiki::Plugins::VERSION < 2.2 ) {
        Foswiki::Func::writeWarning( 'Version mismatch between ',
            __PACKAGE__, ' and Plugins.pm' );
        return 0;
    }

    Foswiki::Func::registerTagHandler( 'MULTISEARCH',  \&_MULTISEARCH );

    return 1;
}


=begin TML

---++ _fetchFormFieldValue($field, $meta) -> $value

Fetch the raw unrendered content of a formfield

The parameter is:
   * =$field= - Field name to fetch.
   * =$meta=  - Meta object of topic

The sub returns
   * String - The raw content in the field
   * Returns '' if field does not exist

=cut

sub _fetchFormFieldValue {
    my ( $field, $meta ) = @_;

    my $value = $meta->get( 'FIELD', $field );

    my $returnvalue = defined $value ? $value->{'value'} : '';

    return $returnvalue;
}

sub _convertStringToDate {
    my ($text, $relativeDate ) = @_;

    return undef if !defined $text;
    return undef if $text eq '';
    return undef if ( $text =~ /^\s*$/ );
    
    my $date = Foswiki::Time::parseTime($text);
    
    return $date if defined $date;
    
    # OK, the date may be given as relative to today
    
    # We get time of last passed midnight representing today
    unless ( defined $relativeDate ) {
        my ( $sec, $min, $hour, $day, $mon, $year, $wday, $yday ) = gmtime();
        $relativeDate = timegm( 0, 0, 0, $day, $mon, $year );
    }

    $date = Time::ParseDate::parsedate( $text,
                                        NO_RELATIVE => 0,
                                        DATE_REQUIRED => 1,
                                        UK => 1,
                                        NOW => $relativeDate,
                                        PREFER_FUTURE => 1,
                                        GMT => 1
                                      );
    
    # return undef if we failed at calucating anything
    return undef unless defined $date;

    return $date;
}

# _MULTISEARCH
#
#  $session= - a reference to the Foswiki session object
#  $params=  - a reference to a Foswiki::Attrs object containing
#              parameters.
#              This can be used as a simple hash that maps parameter names
#              to values, with _DEFAULT being the name for the default
#              (unnamed) parameter.
#  $topic    - name of the topic in the query
#  $web      - name of the web in the query
#  $topicObject - a reference to a Foswiki::Meta object containing the
#              topic the macro is being rendered in (new for foswiki 1.1.x)
#  Return: the result of processing the macro. This will replace the
#  macro call in the final text.
#
#  For example, %EXAMPLETAG{'hamburger' sideorder="onions"}%
#  $params->{_DEFAULT} will be 'hamburger'
#  $params->{sideorder} will be 'onions'
#
#  Below is the help text for the Foswiki::Func::query
#
#  query($searchString, $topics, \%options ) -> iterator (resultset)
#
#  query the topic data in the specified webs. A programatic interface to SEARCH results.
#
#    * =$searchString= - the search string, as appropriate for the selected type
#    * =$topics= - undef OR reference to a ResultSet, Iterator, or array containing the web.topics to be evaluated.
#                  if undef, then all the topics in the webs specified will be evaluated.
#    * =\%option= - reference to an options hash
# The =\%options= hash may contain the following options:
#    * =type= - =regex=, =keyword=, =query=, ... defaults to =query=
#    * =web= - The web/s to search in - string can have the same form as the =web= param of SEARCH (if not specified, defaults to BASEWEB)
#    * =casesensitive= - false to ignore case (default true)
#    * =files_without_match= - true to return files only (default false). If =files_without_match= is specified, it will return on the first match in each topic (i.e. it will return only one match per
#    * topic, excludetopic and other params as per SEARCH
#
# To iterate over the returned topics use:
# <verbatim>
#     my $matches = Foswiki::Func::query( "Slimy Toad", undef,
#             { web => 'Main,San*', casesensitive => 0, files_without_match => 0 } );
#     while ($matches->hasNext) {
#         my $webtopic = $matches->next;
#         my ($web, $topic) = Foswiki::Func::normalizeWebTopicName('', $webtopic);
#       ...etc
# </verbatim>
#

sub _MULTISEARCH {
    my ( $session, $params, $theTopic, $theWeb ) = @_;

    my $ignored       = $params->{_DEFAULT};
    my $paramWeb      = $params->{web} || $theWeb;
    my $lineFormat    = $params->{"format"} || '';
    my $header        = $params->{header} || '';
    my $footer        = $params->{footer} || '';
    my $indexType     = $params->{indextype} || 'text'; # text, multi, date
    my $indexFormat   = $params->{indexformat} || '';   # date formats
    my $indexMode     = $params->{indexmode} || 'index'; # index, interval
    my $indexStart    = $params->{indexstart};
    my $indexEnd      = $params->{indexend};
    my $indexStep     = $params->{indexstep} || "1";

    my @multiSearchStrings;
    my @listFormats;
    my @listSeparators;
    my @indexFields;
    
    my $searchCounter = 1;
    while ( defined $params->{"search$searchCounter"} ) {
        $multiSearchStrings[$searchCounter] = $params->{"search$searchCounter"};
        $listFormats[$searchCounter]        = defined $params->{"listformat$searchCounter"}
                                            ? $params->{"listformat$searchCounter"}
                                            : '';
        $listSeparators[$searchCounter]     = defined $params->{"listseparator$searchCounter"}
                                            ? $params->{"listseparator$searchCounter"}
                                            : '';
        $indexFields[$searchCounter]        = defined $params->{"indexfield$searchCounter"}
                                            ? $params->{"indexfield$searchCounter"}
                                            : '';
        $searchCounter++;
    }

    #We decrease by 1 and have the number of found search strings
    $searchCounter--;

    return "No searches found" unless $searchCounter;

    my %valueIndex;

    for ( my $i = 1 ; $i <= $searchCounter ; $i++ ) {

        # First we find all topics that matches the search
        # Note that this plugin always assumes a query type search
        my $matches = Foswiki::Func::query( "$multiSearchStrings[$i]", undef,
            { web => $paramWeb, casesensitive => 0, files_without_match => 0, 
              type => 'query' }
        );

        # For each found topic we fetch the value of the indexField
        while ( $matches->hasNext ) {

            my $fullTopicName = $matches->next;

            my ( $web, $topic ) =
              Foswiki::Func::normalizeWebTopicName( '', $fullTopicName );

            my ( $meta, undef ) = Foswiki::Func::readTopic( $web, $topic );

            my $indexFieldValue =
              _fetchFormFieldValue( $indexFields[$i], $meta );
              
            my $listFormat = $listFormats[$i];
            $listFormat =~ s/\$web/$web/gs;
            $listFormat =~ s/\$topic/$topic/gs;

            # For each formfield we need to now fetch the field values now
            # that the meta is loaded
            $listFormat =~ s/\$formfield\(\s*([^\)]*)\s*\)/_fetchFormFieldValue( $1, $meta )/ges;

            if ( $indexType eq 'multi' ) {
                map {
                    s/^\s*(.*?)\s*$/$1/;
                    $valueIndex{$_}{$i}{$fullTopicName} = $listFormat;
                } split( /\s*,\s*/, $indexFieldValue );
            }
            else {
                $valueIndex{$indexFieldValue}{$i}{$fullTopicName} = $listFormat;
            }
        }
    }


    my $resultString = '';
    my @totalFound;

    if ( $indexMode eq 'index' ) {
    
        # Now we iterate through all indexField sorted values in all searches
        foreach my $indexText ( sort keys %valueIndex ) {
            my $result = $lineFormat;
    
            for ( my $i = 1 ; $i <= $searchCounter ; $i++ ) {
    
                # We build the formatted list for each indexText and for each search   
    
                my $formatList = join( $listSeparators[$i], values %{ $valueIndex{$indexText}{$i} } );
    
                my $topicCount = keys %{ $valueIndex{$indexText}{$i} };
                $totalFound[$i] += $topicCount;
    
                $result =~ s/\$indexfield/$indexText/gs;
                $result =~ s/\$list$i/$formatList/gs;
                $result =~ s/\$nhits$i/$topicCount/gs;
                $result =~ s/\$ntotal$i/$totalFound[$i]/gs;
                $result = Foswiki::Func::decodeFormatTokens($result);
            }
            $resultString .= $result;
        }
    } elsif ( $indexMode eq 'interval' ) {
        my $start = $indexStart;
        my $end = $indexEnd;
        my $step = $indexStep || 1;

        # We need to sort all the indexes
        # I need one array per search
        
        my @sortedIndexes = ();

        foreach my $valueIx ( keys %valueIndex ) {
            foreach my $searchPass ( keys %{ $valueIndex{$valueIx}} ) {
                foreach my $webTopic ( keys %{ $valueIndex{$valueIx}{$searchPass} } ) {
                    my $tempValue = $valueIx;
                    $tempValue = Foswiki::Time::parseTime( $tempValue ) if ( $indexType eq 'date' );
                    
                    push @{$sortedIndexes[$searchPass]},
                         { formatlist => $valueIndex{$valueIx}{$searchPass}{$webTopic},
                           indexvalue => $tempValue };
                }
            }
        }

        for ( my $i = 1 ; $i <= $searchCounter ; $i++ ) {
                      
            @{$sortedIndexes[$i]} = sort { $a->{indexvalue} <=> $b->{indexvalue} } @{$sortedIndexes[$i]};
        }

        my $cnt = 0;

        if ( $indexType eq 'date' ) {
            # Let us calculate all time into epoch
            $indexStart = _convertStringToDate($indexStart, undef);
            $indexEnd   = _convertStringToDate($indexEnd, undef);
            # We get relative by passing epoch as reference date
            $indexStep  = _convertStringToDate($indexStep, 0);
        } 

        return "End value must be larger or later than start value" if ($indexStart >= $indexEnd);
        return "Cannot have an index step of 0 or negative" if ($indexStep <= 0);
        
        # This loops each interval
        for ( my $ix = $indexStart; $ix < $indexEnd; $ix += $indexStep ) {
            my $result = $lineFormat;
            
            # Within each interval this loops each search
            for ( my $i = 1 ; $i <= $searchCounter ; $i++ ) {
                
                # First we get rid of all that are before the start interval
                while ( exists $sortedIndexes[$i][0]{indexvalue} && 
                        $sortedIndexes[$i][0]{indexvalue}< $ix ) {
                    shift @{$sortedIndexes[$i]};
                }
                
                # This loop finds all topics in each search within the interval
                my $topicCount = 0;
                my @formatLists;

                while ( exists $sortedIndexes[$i][0]{indexvalue} &&
                        $sortedIndexes[$i][0]{indexvalue} >= $ix &&
                        $sortedIndexes[$i][0]{indexvalue} < $ix + $indexStep ) {
                        
                    $topicCount++;
                    push @formatLists, $sortedIndexes[$i][0]{formatlist};                     

                    shift @{$sortedIndexes[$i]};
                            
                }
                
                my $formatList = join( $listSeparators[$i], @formatLists );
                
                $totalFound[$i] += $topicCount;
           
                my $formattedIndex = $ix;
                if ( $indexFormat && $indexType eq 'date') {
                    $formattedIndex = Foswiki::Time::formatTime($ix, $indexFormat, gmtime);
                }
  
                $result =~ s/\$indexfield/$formattedIndex/gs;
                $result =~ s/\$list$i/$formatList/gs;
                $result =~ s/\$nhits$i/$topicCount/gs;
                $result =~ s/\$ntotal$i/$totalFound[$i]/gs;
                $result = Foswiki::Func::decodeFormatTokens($result);   
            }
            
            $resultString .= $result;
        }   
        
    } else {
        return "Unknown index mode";
    }


    # Update header and footer
    for ( my $i = 1 ; $i <= $searchCounter ; $i++ ) {
        $header =~ s/\$ntopics$i/$totalFound[$i]/gs;
        $footer =~ s/\$ntopics$i/$totalFound[$i]/gs;
    }
    # decode the usual format tokens of header and footer
    $header = Foswiki::Func::decodeFormatTokens($header);
    $footer = Foswiki::Func::decodeFormatTokens($footer);

    return $header . $resultString . $footer;
}

1;

__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2015 Kenneth Lavrsen, kenneth@lavrsen.dk

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
