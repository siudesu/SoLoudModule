# SoLoud Module
### This [Solar2D](https://solar2d.com) Lua module aims to be a drop-in replacement for the audio API using the [SoLoud plugin](https://forums.solar2d.com/t/soloud-audio-plugin/355040).

</br>

## State: [Testing Phase]
- Might find bugs. Please report any if not [already reported](https://github.com/siudesu/SoLoudModule/issues). 
- Updates are made frequently.

</br>

## Features
 - Uses same API syntax as [Solar2D's audio library](https://docs.coronalabs.com/api/library/audio/index.html)
 - Can play audio files that have been bundled using [Binary Archive](https://github.com/siudesu/BinaryArchive)

</br>

## Limitations
 - Currently, SoLoud plugin is **not available for Linux or Switch**.
 - `stopWithDelay()` is not implemented. The same effect can be accomplished outside this module with a `timer` and `AUDIO.stop()`
 - `fadeOut()` is not implemented. The same effect can be accomplished outside this module with `AUDIO.fade()` and a `timer` to perform `AUDIO.stop()`.

</br>



## Requirements
- [SoLoud plugin](https://github.com/solar2d/com.xibalbastudios-plugin.Bytemap) by [Steven Johnson](https://github.com/ggcrunchy), must be added in `build.settings`.

### build.settings (Plugins section)
```lua
	plugins =
	{
		["plugin.soloud"] = {publisherId = "com.xibalbastudios"},
	}
```

</br>

## Usage
### Load module and play audio sound:
```lua
-- You may replace the original audio library reference with this module without making additional changes to your project:

audio = require( "m_soloud_audio" )

local sfx1 = audio.loadSound( "soundFile.mp3" )
	audio.play( sfx1 )


-- or, load the module with any variable name without replacing the original audio library:

local AUDIO = require( "m_soloud_audio" )

local sfx1 = AUDIO.loadSound( "soundFile.mp3" )
	AUDIO.play( sfx1 )
```


### Loading audio from archive:
```lua
-- Assumes a binary archive has been loaded with audio files used below.

-- Load SoLoud Module
local AUDIO = require( "m_soloud_audio" )

-- Fetch audio data from archive and insert it into a table (it's passed by reference)
local BGM_Data = { bin.fetch( "audio/BGM 01.mp3" )}
local SFX_Data = { bin.fetch( "audio/SFX/Ding.ogg" )}

-- Create audio stream object
local BGM1 = AUDIO.loadStreamFromArchive( "audio/BGM 01.mp3", BGM_Data )

-- Create audio sound object
local SFX1 = AUDIO.loadSoundFromArchive( "audio/SFX/Ding.ogg", SFX_Data )

-- Play BGM on channel 1
AUDIO.play( BGM1, { channel=1 })

-- Play SFX
AUDIO.play( SFX1 )
```

</br>

### Function List - same as [Solar2D audio API](https://docs.coronalabs.com/api/library/audio/index.html):
```
MODULE.dispose()
MODULE.fade()
MODULE.findFreeChannel()
MODULE.getDuration()
MODULE.getMaxVolume()
MODULE.getMinVolume()
MODULE.getVolume()
MODULE.isChannelActive()
MODULE.isChannelPaused()
MODULE.isChannelPlaying()
MODULE.loadSound()
MODULE.loadStream()
MODULE.pause()
MODULE.play()
MODULE.reserveChannels()
MODULE.resume()
MODULE.rewind()
MODULE.seek()
MODULE.setMaxVolume()
MODULE.setMinVolume()
MODULE.setVolume()
MODULE.stop()
```
### Functions - Binary Archive
```
MODULE.loadSoundFromArchive.(filename_, data_)
MODULE.loadStreamFromArchive(filename_, data_)
```

### Properties (Read Only):
```
audio.freeChannels
audio.totalChannels
audio.unreservedFreeChannels
audio.unreservedUsedChannels
audio.usedChannels
```

---

## License
Distributed under the MIT License. See [LICENSE](https://github.com/siudesu/SoLoudModule/blob/main/LICENSE) for more information.
