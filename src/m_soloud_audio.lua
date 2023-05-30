--  SoLoud Module
--  Last Revision: 2023.05.23
--	Lua version: 5.1
--	License: MIT
--	Copyright <2023> <siu>

--[[
 Note:
	This module aims to be a drop-in replacement for Solar2D's audio API using the SoLoud plugin.
	Function names (and functionality) have been matched wherever possible with only two functions
	not implemented from the original audio API (see below on "What to know").

	SoLoud provides a lot more features than Solar2D's audio API, but none have been included here (yet?).
	The biggest perk with using this module is the ability to bundle audio files with Binary Archive and load them
	directly from a created archive.

	SoLoud plugin is currently available only on Windows build.

	Requirements:
		Add SoLoud plugin to Solar2D project in build.settings file:
			--
			-- Plugins section
			--
			plugins =
			{
				["plugin.soloud"] = {publisherId = "com.xibalbastudios"},
			},


	Usage:
		You may replace the original audio library reference with this module without making additional changes to your project:
			audio = require( "m_soloud_audio" )
			local sfx1 = audio.loadSound("soundFile.mp3")
			audio.play(sfx1)

		You can, of course, load the module with any variable name without replacing the original audio library:
			local AUDIO = require( "m_soloud_audio" )
			local sfx1 = AUDIO.loadSound("soundFile.mp3")
			AUDIO.play(sfx1)

	What to know:
	 1. Solar2D's audio API works via a channel/track system. A single audio takes up a single channel.
			Channels are not shared, thus any attempt to play an audio on a busy (playing or paused audio) channel will fail.

	 3. Solar2D's framework is set to a 32 audio channels/tracks limit. For compliance, this module also simulates a 32 channels/tracks system.
			This limit is a soft cap and can be changed if desired. A higher value will not (should not) break the workflow.

	 4. In order to avoid using timers in this module the following are not implemented from the original audio API:
		-- stopWithDelay() ; This is just a timer that stops audio after the specified time has elapsed. The same can be accomplished outside of the module with a timer and AUDIO.stop();
		-- fadeOut() ; This is the same as fade() except it also frees the channel. This can be accomplished outside of the module with fade() and a timer to AUDIO.stop() the audio.
]]


local soloud = require("plugin.soloud")

local debug = debug
local s_gsub = string.gsub
local m_round = math.round
local type = type
local debugMode = true


local M = {}

	-- Initialized @ module load.
	local totalChannels = 32	-- this is the soft cap for channels/tracks
	local cache = {}	-- keep track of loaded files so they are only loaded once
	local STATE = { ["INACTIVE"] = 0, ["PLAYING"] = 1, ["PAUSED"] = 2 }
	local soloudCore = soloud.createCore{ flags = { "CLIP_ROUNDOFF" } }
	local masterVolume = 1
	local maxVolume = 1
	local minVolume = 0
	local channels = {}
	for i=1, totalChannels do -- initialize channel state
		channels[i] = {
			volume = masterVolume,
			minVolume = minVolume,
			maxVolume = maxVolume,
			state = STATE.INACTIVE,
			fileName = nil,	-- string of audio file used
			reserved = false, -- is channel reserved?
			wavObj = nil,	-- reference to the audio object assigned on this channel
			handleID = nil -- id provided by SoLoud's play function, this is currently required in the fade function. 
		} 
	end

	-- Internal use only ----------------------------------------------------------

	local function printDebug()
		if not debugMode then return end
		local info = debug.getinfo(3)
		local file, line, funcName = s_gsub(info.source, "=",""), info.currentline, debug.getinfo(2, "n").name
		print("[SoLoud Module] Trace:\n\tFile: " .. file .. "\n\tLine: " .. line .. ", Function: " .. funcName)
	end
	
	local function clearChannel(channel_)
		if channel_ <= 0 or channel_ > totalChannels then return false end
		local channelData = channels[channel_]
		-- nil the object reference
		channelData.wavObj = nil 

		-- remove file reference
		channelData.fileName = nil
		
		-- clear handle id
		channelData.handleID = nil

		-- clear channel state
		channelData.state = STATE.INACTIVE
	end
	
	local function clearAllChannels(filename_)
		-- Clears all channels if no filename_ is provided.
		-- Clears all channels where the filename_ is currently assign.
		
		if filename_ then -- clear channels assigned with filename_
			for i=1, totalChannels do
				if channels[i].fileName == filename_ then
					channels[i].wavObj:stop()	-- stop in case it's still playing
					clearChannel(i)
				end
			end
			return true
		end
		
		-- Else, clear all channels
		for i=1, totalChannels do
			channels[i].wavObj:stop()	-- stop audio track in case it's still playing
			clearChannel(i)
		end
	end
	
	local function getNextAvailableChannel(startFrom_)
		-- Note: Returns the available channel number, else returns false if none found.
		
		-- Loop through the channels to find one currently not in use and not reserved.
		local from = startFrom_ or 1
		for i=from, totalChannels do
			if not channels[i].reserved and not channels[i].state == STATE.INACTIVE then
				return i;
			end
		end
		return false
	end


	-- Module API -----------------------------------------------------------------

	-------------------------------------
	-- Dispose
	-------------------------------------
	function M.dispose(fileName_)
	-- Solar2D API: audio.dispose( audioHandle )
		
	-- Note: Destroying the audio will also stop the audio.
	-- !Unlike the audio API, it is possible to destroy (without errors) an audio while it's already playing.
		
		-- Destroy audio if it exists.
		if cache[fileName_] then cache[fileName_].wavObj:destroy() end
		
		-- All channels that were playing the audio will be clear.
		clearAllChannels(filename_)
		
		-- Clear cache.
		cache[fileName_] = nil
	end

	-------------------------------------
	-- Fade
	-------------------------------------
	function M.fade(options_)
	-- Solar2D API: audio.fade( [ { [channel=c] [, time=t] [, volume=v ] } ] ) ; ( { channel=1, time=5000, volume=0.5 } )
	-- The audio will continue playing after the fade completes.
	-- When you fade the volume, you are changing the volume of the channel.
	-- Volume levels are still clamped by min/maxVolume

		local o = options_
		if not o then -- apply default values
			o = {}
			o.channel = 0 -- Specify 0 to apply fade to all channels.
			o.volume = 0
			o.time = 1000
		else
			o.channel = options_.channel or 0
			o.volume = options_.volume or 0
			o.time = options_.time or 1000
		end
		
		-- Convert time to SoLoud's expected value
		o.time = o.time * 0.001

		if o.channel == 0 then -- fade all
			for i=1, totalChannels do
				if channels[i].fileName then -- if there's an audio object assigned
					local channelData = channels[i]
					channelData.volume = (( o.volume > channelData.maxVolume ) and channelData.maxVolume ) or (( o.volume < channelData.minVolume ) and channelData.minVolume) or o.volume
					if channelData.wavObj then soloudCore:fadeVolume(channelData.handleID, channelData.volume, o.time) end -- fade its audio 
				end
			end
			return true
		end
		
		-- Else, fade the specified channel.
		local channelData = channels[o.channel]
		channelData.volume = (( o.volume > channelData.maxVolume ) and channelData.maxVolume ) or (( o.volume < channelData.minVolume ) and channelData.minVolume) or o.volume
		soloudCore:fadeVolume(channelData.handleID, channelData.volume, o.time)
	end

	-------------------------------------
	-- Fade Out
	-------------------------------------
	function M.fadeOut__(options_)
	-- Solar2D API: audio.fadeOut( [ { [channel=1] [, time=1000] } ] )
	-- Stops a playing sound in a specified amount of time and fades to min volume while doing it.
	-- The audio will stop at the end of the time and the channel will be freed. 
	-- Specify 0 to fade out all channels.

		local o = options_
		if not o then
			o = {}
			o.channel = 0
			o.time = 1000 -- default fade out time
		end
		
		local channel = o.channel
		if not channel then print("Error: Must provide valid channel value."); printDebug() return false end
		if channel > totalChannels or channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end
		if not o.time then print("Error: Must provide valid time value."); printDebug() return false end
		
		if o.time > 0 then
			M.fade({channel=channel, time=o.time, volume=0})
			soloudCore:scheduleStop(channels[channel].handleID, o.time * 0.001);
			timer.performWithDelay(o.time, function() clearChannel(channel) end)
		end
	end
	
	-------------------------------------
	-- Find Free Channel
	-------------------------------------
	function M.findFreeChannel(startChannel_)
	-- Solar2D API: audio.findFreeChannel( [ startChannel ] )
	-- Search will increase upwards from this channel. 0 or no parameter begins searching at the lowest possible value.
	-- The search does not include reserved channels.

			-- Returns 0 if no available channel found, else it returns next available channel.
			return getNextAvailableChannel(startChannel_ or 0) or 0
	end

	-------------------------------------
	-- Get Duration
	-------------------------------------
	function M.getDuration(filename_)
	-- Solar2D API: audio.getDuration( audioHandle )
	-- This function returns the total time in milliseconds of the audio resource.

		if not filename_ then print("Error: Must provide a valid value for audioHandle"); printDebug() return false end
		if not cache[filename_] then print("Error: Audio not found, is it loaded?"); printDebug() return false end
		if not cache[filename_].wavObj then print("Error: Audio not found, is it loaded?"); printDebug() return false end
		
		-- Return converted value; from SoLouds (seconds) to Solar2D (milliseconds)
		return m_round(cache[filename_].wavObj:getLength() * 1000)
	end
	
	-------------------------------------
	-- Get Max Volume
	-------------------------------------
	function M.getMaxVolume()
	-- Solar2D API: audio.getMaxVolume( { channel=c } )
	-- Specifying 0 will return the average volume across all channels.
	
		if not options_ then	-- get average
			local sum = 0
			for i=1, totalChannels do sum = sum + channels[i].maxVolume end

			-- Calculate the sum of numbers
			return sum / totalChannels
		end
		
		-- Else, get volume for specified channel
		local channel = options_.channel
		if channel > totalChannels or channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end

		return channels[channel].maxVolume
	end
	
	-------------------------------------
	-- Get Min Volume
	-------------------------------------
	function M.getMinVolume(options_)
	-- Solar2D API: audio.getMinVolume( { channel=1 } )
	-- Specifying 0 will return the average volume across all channels.
	
		if not options_ then	-- get average
			local sum = 0
			for i=1, totalChannels do sum = sum + channels[i].minVolume end

			-- Calculate the sum of numbers
			return sum / totalChannels
		end
		
		-- Else, get volume for specified channel
		local channel = options_.channel
		if channel > totalChannels or channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end

		return channels[channel].minVolume
	end
	
	-------------------------------------
	-- Fade Out
	-------------------------------------
	function M.getVolume(options_)
	-- Solar2D API: audio.getVolume( { channel=1 } )
	-- Specifying 0 will return the average volume across all channels.
	
		if not options_ then	-- get average
			local sum = 0
			for i=1, totalChannels do sum = sum + channels[i].volume end

			-- Calculate the sum of numbers
			return sum / totalChannels
		end
		
		-- Else, get volume for specified channel
		local channel = options_.channel
		if channel > totalChannels or channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end

		return channels[channel].volume
	end

	-------------------------------------
	-- Is Channel Active
	-------------------------------------
	function M.isChannelActive(channel_)
		return channels[channel_].state == STATE.PLAYING or channels[channel_].state == STATE.PAUSED
	end
	
	-------------------------------------
	-- Is Channel Paused
	-------------------------------------
	function M.isChannelPaused(channel_)
		return channels[channel_].state == STATE.PAUSED
	end

	-------------------------------------
	-- Is Channel Playing
	-------------------------------------
	function M.isChannelPlaying(channel_)
		return channels[channel_].state == STATE.PLAYING
	end
	
	-------------------------------------
	-- Load Sound
	-------------------------------------
	function M.loadSound(filename_)
		if not filename_ then print("Error: Must provide a valid path for audio file."); printDebug() return false end
		if not cache[filename_] then
			cache[filename_] = {}
			cache[filename_].wavObj = soloud.createWav()
			
			if not cache[filename_].wavObj then print("Error: Could not create wav object."); printDebug() return false end
			if not cache[filename_].wavObj:load(filename_) then print("Error: Could not load audio file:", filename_); printDebug() return false end
		end
		return filename_
	end

	-------------------------------------
	-- Load Sound From Archive
	-------------------------------------
	function M.loadSoundFromArchive(filename_, data_)
		if not filename_ then print("Error: Must provide a valid path for audio file."); printDebug() return false end
		if not cache[filename_] then
			cache[filename_] = {}
			cache[filename_].wavObj = soloud.createWav()
			if not cache[filename_].wavObj then print("Error: Could not create wav object."); printDebug() return false end

			if not cache[filename_].wavObj:loadMem(data_[1]) then print("Error: Could not load audio file:", filename_); printDebug() return false end
		end
		-- Return filename_ as reference
		return filename_
	end

	-------------------------------------
	-- Load Stream
	-------------------------------------
	function M.loadStream(filename_)
		if not filename_ then print("Error: Must provide a valid path for audio file."); printDebug() return false end
		if not cache[filename_] then
			cache[filename_] = {}
			cache[filename_].wavObj = soloud.createWavStream()
			
			if not cache[filename_].wavObj then print("Error: Could not create wav stream."); printDebug() return false end
			if not cache[filename_].wavObj:load(filename_) then print("Error: Could not load audio file:", filename_); printDebug() return false end
		end
		return filename_
	end
	
	-------------------------------------
	-- Load Stream From Archive
	-------------------------------------
	function M.loadStreamFromArchive(filename_, data_)
		if not filename_ then print("Error: Must provide a valid path for audio file."); printDebug() return false end
		if not cache[filename_] then
			cache[filename_] = {}
			cache[filename_].wavObj = soloud.createWavStream()

			if not cache[filename_].wavObj then print("Error: Could not create wav object."); printDebug() return false end
			if not cache[filename_].wavObj:loadMem(data_[1]) then print("Error: Could not load audio file:", filename_); printDebug() return false end
		end
		return filename_
	end

	-------------------------------------
	-- Pause
	-------------------------------------
	function M.pause(channel_)
	-- Solar2D API: audio.pause( [channel] )
	-- Specifying 0 pauses all channels. If channel is omitted, audio.pause() will pause all active channels.

		if not channel_ or channel_ == 0 then -- pauses all channels
			for i=1, totalChannels do
				local channelData = channels[i]
					if channelData.wavObj then
						soloudCore:setPause(channelData.handleID, true) 
						channelData.state = STATE.PAUSED
				end
			end
		end

		-- Else, pause specified channel.
		soloudCore:setPause(channels[channel_].handleID, true)
		channels[channel_].state = STATE.PAUSED
	end

	-------------------------------------
	-- Play
	-------------------------------------
	function M.play(filename_, options_)
	-- Solar2D API: audio.play( audioHandle [, options ] ) ; options = { channel = 1, loops = -1, duration = 30000, fadein = 5000, onComplete = callbackListener }
		
		if not filename_ then print("Error: Must provide a valid audio file name."); printDebug() return false end

		-- Check audio file has already been loaded.
		local cachedData = cache[filename_]
		if not cachedData then print("Error: Audio file must be loaded before playing: " .. filename_); printDebug() return false end
		
		-- Get options_ table.
	 local o = options_
		if not o then	-- assign default values
			o = {}
			o.channel = 0 
			o.loops = 0
			o.duration = 0
			o.fadein = 0
			o.onComplete = nil
		end
		
		-- Verify options_ data.
		cachedData.channel = ( o.channel and (o.channel > 0 and o.channel <= totalChannels) ) and o.channel or getNextAvailableChannel()
		if not cachedData.channel then print("Error: No channels available to play audio."); printDebug() return false end
		
		local channelData = channels[cachedData.channel]
		if channelData.fileName then print("Warning: Channel already in use."); printDebug() return false end -- this can trigger if channel is assigned manually.

		-- Assign channel values.
		channelData.fileName = filename_
		channelData.wavObj = cachedData.wavObj
		channelData.state = STATE.PLAYING

		-- Set looping.
		cachedData.loops = o.loops or 0
		if cachedData.loops > 0 then cachedData.wavObj:setLooping(cachedData.loops) end
		if cachedData.loops == -1 then cachedData.wavObj:setLooping(true) end
		
		-- Piggyback onComplete to clean up channel.
		local onComplete
		if options_.onComplete then
			onComplete = function() 
				clearChannel(cachedData.channel)
				options_.onComplete()
			end
		else
			onComplete = function() 
				clearChannel(cachedData.channel)
			end
		end
		
		-- Set fade in.
		cachedData.fadein = o.fadein or 0 
		if cachedData.fadein > 0 then -- play with fade in effect
			channelData.handleID = soloudCore:play( cachedData.wavObj, { volume = channelData.minVolume, onComplete = onComplete });
			M.fade({channel=cachedData.channel, time=cachedData.fadein, volume=channelData.maxVolume})
		else	-- play normal
			channelData.handleID = soloudCore:play( cachedData.wavObj, { volume = channelData.volume, onComplete = onComplete });
		end

		-- Set duration.
		cachedData.duration = o.duration and o.duration * 0.001 or 0
		if cachedData.duration > 0 then
			soloudCore:scheduleStop(channelData.handleID, cachedData.duration)
		end

		return true
	end
	
	-------------------------------------
	-- Reserved Channels
	-------------------------------------
	function M.reserveChannels(channels_)
	-- Solar2D API: audio.reserveChannels( channels )
	-- If you pass 2 into this function, channels 1 and 2 will be reserved
	-- 0 will un-reserve all channels.
	
		if not channels_ or type(channels_) ~= "number" then print("Error: Must provide a valid value for `channels`"); printDebug() return false end
		if channels_ > totalChannels or channels_ < 0 then print("Error: Channel value not in range."); printDebug() return false end
		
		if channels_ == 0 then -- un-reserve all channels
			for i=1, totalChannels do
				channels[i].reserved = false
			end
			return true		
		end

		-- Else, reserve specified channel/s
		for i=1, channels_ do
			channels[i].reserved = true
		end
		return true
	end

	-------------------------------------
	-- Resume
	-------------------------------------
	function M.resume(channel_)
	-- Solar2D API: audio.resume( [channel] )
	-- Resumes playback on a channel that is paused (or all channels if no channel is specified).
	-- Has no effect on channels that aren't paused.

		if not channel_ or channel_ == 0 then -- pauses all channels
			for i=1, totalChannels do
				local channelData = channels[i]
					if channelData.wavObj and channelData.state == STATE.PAUSED then
						soloudCore:setPause(channelData.handleID, false) 
						channelData.state = STATE.PLAYING
				end
			end
			return true
		end

		-- Else, resume specified channel.
		soloudCore:setPause(channels[channel_].handleID, false)
		channels[channel_].state = STATE.PLAYING
	end
	
	-------------------------------------
	-- Rewind
	-------------------------------------
	function M.rewind(value_)
	-- Solar2D API: audio.rewind( [audioHandle | options] ) ; audio.rewind( backgroundMusic ) or audio.rewind( { channel=1 } ) 
	--  (rewinds all channels if no arguments are specified).
	-- Audio loaded with audio.loadSound() may only rewind using the channel parameter. You may not rewind using the audio handle.
	-- The audioHandle of the data you want to rewind. Should only be used for audio loaded with audio.loadStream(). 
	-- 	Do not use the channel parameter in the same call.
	
		-- if options is a channel
		if type(value_) == "table" then
			local channel = value_.channel
			if channel > totalChannels or channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end
			if channels[channel].handleID then soloudCore:seek(channels[channel].handleID, 0); end
		end
		
		-- Else, rewind by handle
		if not cache[value_] then print("Error: Audio handle not found: " .. tostring(value_)); printDebug() return false end
		if cache[value_].wavObj then soloudCore:seek(channels[cache[value_].channel].handleID, 0); end
	end
	
	-------------------------------------
	-- Seek
	-------------------------------------
	function M.seek(time_, value_)
	-- Solar2D API: audio.seek( time [, audioHandle ] [, options ] )

		if not time_ then print("Error: Must provide a valid value for `time`"); printDebug() return false end
		
		-- if options is a channel
		if type(value_) == "table" then
			local channel = value_.channel
			if channel > totalChannels or channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end
			if channels[channel].handleID then soloudCore:seek(channels[channel].handleID, time_) return true end
		end
		
		-- Else, seek by handle
		if not cache[value_] then print("Error: Audio handle not found: " .. tostring(value_)); printDebug() return false end
		if cache[value_].wavObj then soloudCore:seek(channels[cache[value_].channel].handleID, time_); end

	end
	
	-------------------------------------
	-- Set Max Volume
	-------------------------------------
	function M.setMaxVolume( volume_, options_ )
	-- Solar2D API: audio.setMaxVolume( 0.75, { channel=1 } )
	-- Specify 0 to apply the max volume to all channels.

		if not volume_ then print("Error: Must provide a valid value for volume"); printDebug() return false end
		
		local o = options_
		if not o then  -- set volume for all channels
			for i=1, totalChannels do
				local channelData = channels[i]
					channelData.maxVolume = volume_
					channelData.volume =  (( channelData.volume > channelData.maxVolume ) and channelData.maxVolume ) or volume_
					
				-- if there's an audio object assigned then adjust audio and
				if channelData.wavObj then soloudCore:setVolume(channelData.handleID, channelData.volume)  end -- update volume
			end
			return true
		end

		-- Else, adjust volume to specified channel
		if o.channel > totalChannels or o.channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end
		
		local channelData = channels[o.channel]
			channelData.maxVolume = volume_
			channelData.volume = (( channelData.volume > channelData.maxVolume ) and channelData.maxVolume ) or volume_
			
		-- if there's an audio object assigned then adjust audio and
		if channelData.wavObj then soloudCore:setVolume(channelData.handleID, channelData.volume)  end -- update volume
	end

	-------------------------------------
	-- Set Min Volume
	-------------------------------------
	function M.setMinVolume( volume_, options_ )
	-- Solar2D API: audio.setMaxVolume( 0.75, { channel=1 } )
	-- Specify 0 to apply the max volume to all channels.

		if not volume_ then print("Error: Must provide a valid value for volume"); printDebug() return false end
		
		local o = options_
		if not o then  -- set volume for all channels
			for i=1, totalChannels do
				local channelData = channels[i]
					channelData.minVolume = volume_
					channelData.volume = (( channelData.volume < channelData.minVolume ) and channelData.minVolume ) or volume_

				-- if there's an audio object assigned then adjust audio and
				if channelData.wavObj then soloudCore:setVolume(channelData.handleID, channelData.volume)  end -- update volume
			end
			return true
		end

		-- Else, adjust volume to specified channel
		if o.channel > totalChannels or o.channel < 0 then print("Error: Audio channel not in range."); printDebug() return false end
		
		local channelData = channels[o.channel]
			channelData.maxVolume = volume_
			channelData.volume = (( channelData.volume < channelData.minVolume ) and channelData.minVolume ) or volume_
			
		-- if there's an audio object assigned then adjust audio and
		if channelData.wavObj then soloudCore:setVolume(channelData.handleID, channelData.volume)  end -- update volume
	end
	
	-------------------------------------
	-- Set Volume
	-------------------------------------
	function M.setVolume(volume_, options_)
	-- Solar2D API: audio.setVolume( 0.75, { channel=1 } ) 

		-- If options_ is not provided then all channels are affected individually.
		if not options_ then  
			for i=1, totalChannels do
				local channelData = channels[i]
					channelData.volume = (( volume_ > channelData.maxVolume ) and channelData.maxVolume ) or (( volume_ < channelData.minVolume ) and channelData.minVolume) or volume_
				
				-- if there's an audio object assigned then apply the new volume level
				if channelData.wavObj then soloudCore:setVolume(channelData.handleID, channelData.volume) end
			end
			return
		end

		-- If options_.channel == 0 then the master volume is updated.
		masterVolume = volume_
		if options_.channel == 0 then soloudCore:setGlobalVolume(masterVolume) ; return end

		-- Else, update the specified channel.
		local channelData = channels[options_.channel]
		channelData.volume = (( volume_ > channelData.maxVolume ) and channelData.maxVolume ) or (( volume_ < channelData.minVolume ) and channelData.minVolume) or volume_

		-- If there's an audio object assigned then apply the new volume level.
		if channelData.wavObj then soloudCore:setVolume(channelData.handleID, channelData.volume) end
	end
	
	-------------------------------------
	-- Stop
	-------------------------------------
	function M.stop(channel_)
	-- Solar2D API: audio.stop( [channel] ) ; if no parameter is passed, all channels are stopped.

	-- Note: This function stops the audio, but also clears the channel/s, thus
	-- once audio is stopped it cannot be resumed, rewind, or perform any channel related function.

		-- If no channel is provided then all channels are affected.
		if not channel_ then  
			for i=1, totalChannels do
				-- if there's an audio object assigned then stop audio.
				if channels[i].wavObj then channels[i].wavObj:stop() end -- stop audio
				clearChannel(i) -- clear channel
			end
			return true
		end
	
		-- Do nothing else if channel is not valid.
		if channel_ <= 0 or channel_ > totalChannels then return false end

		-- Else, clear the designated channel.
		if cache[channels[channel_].fileName].wavObj then
			cache[channels[channel_].fileName].wavObj:stop()	-- stop audio
			clearChannel(channel_) -- clear channel
			return true
		end
		return false
	end

	-------------------------------------
	-- Stop With Delay
	-------------------------------------
	function M.stopWithDelay__(duration_, options_)
	-- Solar2D API: audio.stopWithDelay( duration [, options ] )
	-- If no parameter is passed, all channels are stopped.
		if not duration_ then print("Error: Must provide a valid duration value."); printDebug() return false end
		
		if not options_ then -- stop all channels
			for i=1, totalChannels do
				-- if there's an audio object assigned then schedule the audio stop.
				if channels[i].wavObj then 
					soloudCore:scheduleStop(channels[channel].handleID, duration_ * 0.001); -- convert time to SoLoud time.
					timer.performWithDelay(duration_, function() clearChannel(i) end) -- clear channel
				end 
			end
			return true			
		end
	end

	-- Return audio property values; these are meant to be read-only.
	-- The channels table is (should be) small enough that these values can be calculated at time of inquiry
	-- rather than keeping track of all these values throughout the module.
	setmetatable(M, {__index = function(_, key)
		if key == "totalChannels" then return totalChannels end
		if key == "freeChannels" then -- This property is equal to the number of channels that are currently available for playback (channels not playing or paused).
			local freeChannels = 0
			for i=1, totalChannels do
				if channels[i].state == STATE.INACTIVE then freeChannels = freeChannels + 1 end
			end
			return freeChannels
		end
		if key == "unreservedFreeChannels" then --Return the number of channels that are currently available for playback (channels not playing or paused), excluding the channels which have been reserved.
			local unreservedFreeChannels = 0
			for i=1, totalChannels do
				if channels[i].state == STATE.INACTIVE and not channels[i].reserved then unreservedFreeChannels = unreservedFreeChannels + 1 end
			end
			return unreservedFreeChannels
		end
		if key == "unreservedUsedChannels" then --Return the number of channels that are currently in use (playing or paused), excluding the channels which have been reserved.
			local unreservedUsedChannels = 0
			for i=1, totalChannels do
				if channels[i].state ~= STATE.INACTIVE and not channels[i].reserved then unreservedUsedChannels = unreservedUsedChannels + 1 end
			end
			return unreservedUsedChannels
		end
		if key == "usedChannels" then --Return the number of channels that are currently in use (playing or paused).
			local usedChannels = 0
			for i=1, totalChannels do
				if channels[i].state ~= STATE.INACTIVE then usedChannels = usedChannels + 1 end
			end
			return usedChannels
		end		
		return "Property not found: " .. key
	end})

return M