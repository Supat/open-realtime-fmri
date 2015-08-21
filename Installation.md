# Requirements #
A fast PC with Matlab, preferably r2010b or later.

# Downloading and installing #
  * Make a new directory, perhaps called "realtime", where you will store everything. Below, we'll refer to this as {realtime\_dir}
  * Retrieve code from SVN using
```
 svn co https://open-realtime-fmri.googlecode.com/svn {realtime_dir}
```
  * Download spm8 from http://www.fil.ion.ucl.ac.uk/spm/software/ into {realtime\_dir} and unzip

# Low latency export from Siemens Trio #
_Disclaimer: This is a description of what has worked for us. However, please note you follow any advice on this page at your own risk._

We use the excellent gui\_streamer tool from the Donders
  * http://fieldtrip.fcdonders.nl/development/realtime/fmri?s[]=gui&s[]=streamer
Their source and compiled code is available here
  * http://code.google.com/p/fieldtrip/source/browse/trunk/realtime/acquisition/siemens/
You need to copy to or share with the scanner the following two files: gui\_streamer.exe and pthreadGC2.dll

# Receiving data from the console on the realtime machine #
The client that receives data from the scanner uses another fieldtrip component, a "buffer"
  * http://fieldtrip.fcdonders.nl/development/realtime/buffer?s[]=buffer