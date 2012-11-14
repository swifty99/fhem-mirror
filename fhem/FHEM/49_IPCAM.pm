# $Id$
################################################################
#
#  (c) 2012 Copyright: Martin Fischer (m_fischer at gmx dot de)
#  All rights reserved
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
################################################################

package main;
use strict;
use warnings;

sub IPCAM_getSnapshot($);
sub IPCAM_guessFileFormat($);

my %gets = (
  "image"     => "",
  "last"      => "",
  "snapshots" => "",
);

#####################################
sub
IPCAM_Initialize($$)
{
  my ($hash) = @_;

  $hash->{DefFn}    = "IPCAM_Define";
  $hash->{UndefFn}  = "IPCAM_Undef";
  $hash->{GetFn}    = "IPCAM_Get";
  $hash->{AttrList} = "delay credentials path query snapshots storage timestamp:0,1 ".
                      "do_not_notify:1,0 showtime:1,0 ".
                      "loglevel:0,1,2,3,4,5,6 disable:0,1";
}

#####################################
sub
IPCAM_Define($$) {
  my ($hash, $def) = @_;

  # define <name> IPCAM <camip:port>
  # define webcam IPCAM 192.168.1.58:81

  my @a = split("[ \t][ \t]*", $def);

  return "Wrong syntax: use 'define <name> IPCAM <camip:port>'"
    if(@a != 3);

  my $name  = $a[0];
  my $auth  = $a[2];

  $hash->{AUTHORITY} = $auth;
  $hash->{STATE}     = "Defined";
  $hash->{SEQ}       = 0;

  return undef;
}

#####################################
sub
IPCAM_Undef($$) {
  my ($hash, $name) = @_;

  delete($modules{IPCAM}{defptr}{$hash->{NAME}});
  RemoveInternalTimer($hash);

  return undef;
}

#####################################
sub
IPCAM_Get($@) {
  my ($hash, @a) = @_;
  my $modpath = $attr{global}{modpath};
  my $name = $hash->{NAME};
  my $seqImages;
  my $seqDelay;
  my $seqWait;
  my $storage = (defined($attr{$name}{storage}) ? $attr{$name}{storage} : "$modpath/www/snapshots");

  # check syntax
  return "argument is missing @a"
    if(int(@a) != 2);
  # check argument
  return "Unknown argument $a[1], choose one of ".join(" ", sort keys %gets)
    if(!defined($gets{$a[1]}));
  # check attributes
  return "Attribute 'path' is missing. Please add this attribute first!"
    if(!defined($attr{$name}) || (defined($attr{$name}) && !defined($attr{$name}{path})));
  return "Attribute 'path' is defined but empty."
    if(defined($attr{$name}{path}) && $attr{$name}{path} eq "");
  return "Attribute 'query' is defined but empty."
    if(defined($attr{$name}{query}) && $attr{$name}{query} eq "");

  # define default storage
  if(!defined($attr{$name}{storage}) || $attr{$name}{storage} eq "") {
    $attr{$name}{storage} = $storage;
  }

  if(! -d $storage) {
    my $ret = mkdir "$storage";
    if($ret == 0) {
      Log 1, "ipcam Error while creating: $storage: $!";
      return "Error while creating storagepath $storage: $!";
    }
  }
 
  # get argument
  my $arg = $a[1];

  if($arg eq "image") {

    $seqImages = int(defined($attr{$name}{snapshots}) ? $attr{$name}{snapshots} : 1);
    $seqDelay  = int(defined($attr{$name}{delay}) ? $attr{$name}{delay} : 0);
    $seqWait   = 0;

    # housekeeping after number of sequence has changed
    my $readings = $hash->{READINGS};
    foreach my $r (sort keys %{$readings}) {
      if($r =~ /snapshot\d+/) {
        my $n = $r;
        $n =~ s/snapshot//;
        delete $readings->{$r} if( $r =~ m/snapshot/ && int($n) > $seqImages);
        Log 5, "IPCAM $name remove old reading: $r";
        
      }
    }
    $hash->{READINGS}{snapshots}{VAL} = 0;
    for (my $i=0;$i<$seqImages;$i++) {
      InternalTimer(gettimeofday()+$seqWait, "IPCAM_getSnapshot", $hash, 0);
      $seqWait = $seqWait + $seqDelay;
    }
    return undef;

  } elsif(defined($hash->{READINGS}{$arg})) {

    if(defined($hash->{READINGS}{$arg}{VAL})) {
      return "$name $arg => $hash->{READINGS}{$arg}{VAL}";
    } else {
      return "$name $arg => undef";
    }

  }

}

#####################################
sub
IPCAM_getSnapshot($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $camAuth = $hash->{AUTHORITY};
  my $camURI;
  my $camPath;
  my $camQuery;
  my $camCredentials;
  my $imageFile;
  my $imageFormat;
  my $lastSnapshot;
  my $snapshot;
  my $dateTime;
  my $modpath = $attr{global}{modpath};
  my $seq = int(defined($hash->{SEQ}) ? $hash->{SEQ} : 0);
  my $seqImages = int(defined($attr{$name}{snapshots}) ? $attr{$name}{snapshots} : 1);
  my $seqF;
  my $seqL = length($seqImages);
  my $storage = (defined($attr{$name}{storage}) ? $attr{$name}{storage} : "$modpath/www/snapshots");
  my $timestamp;

  #if(!$storage) {
  #  RemoveInternalTimer($hash);
  #  return "Attribute 'storage' is missing. Please add this attribute first!";
  #}

  $camPath  = $attr{$name}{path};
  $camQuery = $attr{$name}{query}
    if(defined($attr{$name}{query}) && $attr{$name}{query} ne "");

  $camURI  = "http://$camAuth/$camPath";
  $camURI .= "?$camQuery" if($camQuery);

  if($camURI =~ m/{USERNAME}/ || $camURI  =~ m/{PASSWORD}/) {

    if(defined($attr{$name}{credentials})) {
      if(!open(CFG, $attr{$name}{credentials})) {
        Log 1, "IPCAM $name Cannot open credentials file: $attr{$name}{credentials}";
        RemoveInternalTimer($hash);
        return undef; 
      }
      my @cfg = <CFG>;
      close(CFG);
      my %credentials;
      eval join("", @cfg);
      $camURI =~ s/{USERNAME}/$credentials{$name}{username}/;
      $camURI =~ s/{PASSWORD}/$credentials{$name}{password}/;
    }
  }

  $dateTime = TimeNow();
  $timestamp = $dateTime;
  $timestamp =~ s/ /_/g;
  $timestamp =~ s/(:|-)//g;

  $snapshot = GetFileFromURLQuiet($camURI);

  $imageFormat = IPCAM_guessFileFormat(\$snapshot);

  my @imageTypes = qw(JPEG PNG GIF TIFF BMP ICO PPM XPM XBM SVG);

  if( ! grep { $_ eq "$imageFormat"} @imageTypes) {
    Log 1, "IPCAM $name Wrong or not supported image format: $imageFormat";
    RemoveInternalTimer($hash);
    return undef;
  }

  Log GetLogLevel($name,5), "IPCAM $name Image Format: $imageFormat";

  readingsBeginUpdate($hash);
  if($seq < $seqImages) {
    $seq++;
    $seqF = sprintf("%0${seqL}d",$seq);
    $imageFormat = "JPG" if($imageFormat eq "JPEG");
    
    $lastSnapshot = $name."_snapshot.".lc($imageFormat);
    if(defined($attr{$name}{timestamp}) && $attr{$name}{timestamp} == 1) {
      $imageFile = $name."_".$timestamp.".".lc($imageFormat);
    } else {
      $imageFile = $name."_snapshot_".$seqF.".".lc($imageFormat);
    }
    if(!open(FH, ">$storage/$lastSnapshot")) {
      Log 1, "IPCAM $name Can't write $storage/$lastSnapshot: $!";
      RemoveInternalTimer($hash);
      readingsEndUpdate($hash, defined($hash->{LOCAL} ? 0 : 1));
      return undef;
    }
    print FH $snapshot;
    close(FH);
    Log 5, "IPCAM $name snapshot $storage/$lastSnapshot written.";
    if(!open(FH, ">$storage/$imageFile")) {
      Log 1, "IPCAM $name Can't write $storage/$imageFile: $!";
      RemoveInternalTimer($hash);
      readingsEndUpdate($hash, defined($hash->{LOCAL} ? 0 : 1));
      return undef;
    }
    print FH $snapshot;
    close(FH);
    Log 5, "IPCAM $name snapshot $storage/$imageFile written.";
    readingsBulkUpdate($hash,"last",$lastSnapshot);
    $hash->{STATE} = "last: $dateTime";
    $hash->{READINGS}{"snapshot$seqF"}{TIME} = $dateTime;
    $hash->{READINGS}{"snapshot$seqF"}{VAL}  = $imageFile;
  }

  Log GetLogLevel($name,4), "IPCAM $name image: $imageFile";

  if($seq == $seqImages) {
    readingsBulkUpdate($hash,"snapshots",$seq);
    $seq = 0;
  }
  readingsEndUpdate($hash, defined($hash->{LOCAL} ? 0 : 1));
  $hash->{SEQ}  = $seq;

  return undef;
}

#####################################
sub
IPCAM_guessFileFormat($) {
  my ($src) = shift;
  my $header;
  my $srcHeader;

  open(my $s, "<", $src) || return "can't open source image: $!";
  $src = $s;

  my $reading = read($src, $srcHeader, 64);
  return "error while reading source image: $!" if(!$reading);

  local($_) = $srcHeader;
  return "JPEG" if /^\xFF\xD8/;
  return "PNG"  if /^\x89PNG\x0d\x0a\x1a\x0a/;
  return "GIF"  if /^GIF8[79]a/;
  return "TIFF" if /^MM\x00\x2a/;
  return "TIFF" if /^II\x2a\x00/;
  return "BMP"  if /^BM/;
  return "ICO"  if /^\000\000\001\000/;
  return "PPM"  if /^P[1-6]/;
  return "XPM"  if /(^\/\* XPM \*\/)|(static\s+char\s+\*\w+\[\]\s*=\s*{\s*"\d+)/;
  return "XBM"  if /^(?:\/\*.*\*\/\n)?#define\s/;
  return "SVG"  if /^(<\?xml|[\012\015\t ]*<svg\b)/;
  return "unknown";
}

# vim: ts=2:et

1;

=pod
=begin html

<a name="IPCAM"></a>
<h3>IPCAM</h3>
<ul>
  <br>

  <a name"IPCAMdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; IPCAM &lt;ip[:port]&gt;</code>
    <br><br>

    Defines a network camera device to trigger snapshots on events.<br><br>

    Network cameras (IP cameras) usually have a build-in function to create
    snapshot images. This module enables the event- or time-controlled
    recording of these images.<br>
    In addition, this module allows the recording of many image formats like
    JPEG, PNG, GIF, TIFF, BMP, ICO, PPM, XPM, XBM and SVG. The only requirement
    is that the recorded image must be accessible via a URL.<br>
    So it is also possible to record images of e.g. a public Weather Camera
    from the internet or any picture of a website.<br><br>

    Examples:<br><br>
    A local ip-cam takes 5 snapshots with 10 seconds delay per call:<br>
    <ul>
      <code>define ipcam IPCAM 192.168.1.205</code><br>
      <code>attr ipcam delay 10</code><br>
      <code>attr ipcam path snapshot.cgi?user=foo&amp;pwd=bar</code><br>
      <code>attr ipcam snapshots 5</code><br>
      <code>attr ipcam storage /srv/share/surveillance/snapshots</code><br>
    </ul><br>

    A notify on a motion detection of a specified device:<br>
    <ul>
      <code>define MOTION.not.01 notify GH.ga.SEC.MD.01:.*on.* get ipcam image</code><br>
    </ul><br>

    Send an eMail after snapshots are taken:<br>
    <ul>
      <code>define MOTION.not.02 notify ipcam:.*snapshots.* { myEmailFunction("%NAME") }</code><br>
    </ul><br>

    A public web-cam takes only 1 snapshot per call:<br>
    <ul>
      <code>define schloss IPCAM http://www2.braunschweig.de</code><br>
      <code>attr schloss path webcam/schloss.jpg</code><br>
      <code>attr schloss storage /srv/share/surveillance/snapshots</code><br>
    </ul><br>

    An at-Job takes every hour a snapshot:<br>
    <ul>
      <code>define snapshot_schloss at +*00:01:00 get schloss image</code><br>
    </ul><br>

  </ul>

  <b>Set</b> <ul>N/A</ul><br>

  <a name="IPCAMget"></a>
  <b>Get</b>
  <ul>
    <code>get &lt;name&gt; &lt;value&gt;</code>
    <br><br>
    where <code>value</code> is one of:<br>
    <ul>
      <li>
        <code>image</code><br>
        Get one or more images of the defined IP-Cam. The number of images<br>
        and the time interval between images can be specified using the<br>
        attributes <code>snapshots</code> and <code>delay</code>.
      </li>
      <li>
        <code>last</code><br>
        Show the name of the last snapshot.
      </li>
      <li>
        <code>snapshots</code><br>
        Show the total number of a image sequence.
      </li>
    </ul>
  </ul>
  <br>

  <a name="IPCAMattr"></a>
  <b>Attributes</b>
  <ul>
    <li>
      credentials<br>
      Defines the location of the credentials file.<br>
      If you prefer to store your cam credentials in a file instead be a part of the
      URI (see attributes <code>path</code> and <code>query</code>), set the full path
      with filename on this attribute.<br>
      Example: <code>attr ipcam3 credentials /etc/fhem/ipcam.conf</code><br><br>

      The credentials file has the following structure:<br>
      <pre>
      #
      # Webcam credentials
      #
      $credentials{&lt;name_cam1&gt;}{username} = "&lt;your_username&gt;";
      $credentials{&lt;name_cam1&gt;}{password} = "&lt;your_password&gt;";
      $credentials{&lt;name_cam2&gt;}{username} = "&lt;your_username&gt;";
      $credentials{&lt;name_cam2&gt;}{password} = "&lt;your_password&gt;";
      ...
      </pre>
      Replace <code>&lt;name_cam1&gt;</code> respectively <code>&lt;name_cam2&gt;</code>
      with the names of your defined ip-cams and <code>&lt;your_username&gt;</code> respectively
      <code>&lt;your_password&gt;</code> with your credentials (all without the brackets
      <code>&lt;</code> and <code>&gt;</code>!).
    </li>
    <li>
      delay<br>
      Defines the time interval between snapshots in seconds.<br>
      If more then one snapshot is taken, then it makes sense to define a short delay
      between the snapshots. On the one hand, the camera is not addressed in short intervals
      and the second may be better represented movements between images.<br>
      Example: <code>attr ipcam3 delay 10</code>
    </li>
    <li><a href="#disable">disable</a></li>
    <li><a href="#do_not_notify">do_not_notify</a></li>
    <li><a href="#loglevel">loglevel</a></li>
    <li>
      path<br>
      Defines the path and query component of the complete <a href="http://de.wikipedia.org/wiki/Uniform_Resource_Identifier" target="_blank">URI</a> to get a snapshot of the
      camera. Is the full URI of your ip-cam for example <code>http://CAMERA_IP/snapshot.cgi?user=admin&amp;pwd=password</code>,
      then only the path and query part is specified here (without the leading slash (/).<br>
      Example: <code>attr ipcam3 path snapshot.cgi?user=admin&amp;pwd=password</code><br><br>

      If you prefer to store the credentials in a file (take a look at the attribute <code>credentials</code>)
      you have to set the placeholder <code>USERNAME</code> and <code>PASSWORD</code> in the path string. These placeholders
      will be replaced with the values from the credentials file.<br>
      Example: <code>attr ipcam3 path snapshot.cgi?user=USERNAME&amp;pwd=PASSWORD</code>
    </li>
    <li><a href="#showtime">showtime</a></li>
    <li>
      snapshots<br>
      Defines the total number of snapshots to be taken with the <code>get &lt;name&gt; image</code> command.
      If this attribute is not defined, then the default value is 1.<br>
      The snapshots are stored in the given path of the attribute <code>storage</code> and are
      numbered sequentially (starts with 1) like <code>snapshot_01</code>, <code>snapshot_02</code>, etc.
      Furthermore, an additional file <code>last</code> will be saved, which is identical with
      the last snapshot-image. The module checks the imagetype and stores all these files with
      the devicename and a correct extension, e.g. <code>&lt;devicename&gt;_snapshot_01.jpg</code>.<br>
      If you like a timestamp instead a sequentially number, take a look at the attribute <code>timestamp</code>.<br>
      All files are overwritten on every <code>get &lt;name&gt; image</code> command (except: snapshots
      with a timestamp. So, keep an eye on your diskspace if you use a timestamp extension!).<br>
      Example: <code>attr ipcam3 snapshots 5</code>
    </li>
    <li>
      storage<br>
      Defines the location for the file storage of the snapshots. Default: <code>$modpath/www/snapshots</code><br>
      Example: <code>attr ipcam3 storage /srv/share/surveillance/snapshots</code>
    </li>
    <li>
      timestamp<br>
      If this attribute is unset or set to 0, snapshots are stored with a sequentially number
      like <code>&lt;devicename&gt;_snapshot_01.jpg</code>, <code>&lt;devicename&gt;_snapshot_02.jpg</code>, etc.<br>
      If you like filenames with a timestamp postfix, e.g. <code>&lt;devicename&gt;_20121023_002602.jpg</code>,
      set this attribute to 1.
    </li>
  </ul>
  <br>

  <a name="IPCAMevents"></a>
  <b>Generated events</b>
  <ul>
    <li>last: &lt;name_of_device&gt;_snapshot.&lt;image_extension&gt;</li>
    <li>snapshots: &lt;total_number_of_taken_snapshots_at_end&gt;</li>
  </ul>
  <br>

</ul>


=end html
=cut