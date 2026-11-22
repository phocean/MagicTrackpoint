-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Jean-Christophe Baptiste

-- "Install MagicTrackpoint" applet, built by scripts/make-dmg.sh.
--
-- A double-clickable script (.command) on a downloaded disk image is blocked
-- by Gatekeeper: Apple's notary service does not cover scripts. This applet is
-- a real, signed and notarized application. Its bundle carries the files to
-- install (Contents/Resources/files), so it also works when macOS runs it from
-- a temporary location (App Translocation).
--
-- It runs the same install script as "make install" (with --prebuilt: no
-- build, no administrator password), then guides through the two macOS
-- permissions with "magictrackpointctl permissions".

property appTitle : "MagicTrackpoint"

on run
	set filesDir to POSIX path of (path to me) & "Contents/Resources/files"
	set homeDir to POSIX path of (path to home folder)
	set ctl to homeDir & ".local/bin/magictrackpointctl"
	set daemon to homeDir & ".local/bin/magictrackpointd"

	display dialog "Install MagicTrackpoint for your user account?" & return & return & ¬
		"It adds a small background helper for the Lenovo ThinkPad TrackPoint Keyboard II. No administrator password is needed." ¬
		buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with title appTitle
	try
		do shell script "cd " & quoted form of filesDir & ¬
			" && /bin/bash scripts/install.sh --prebuilt bin/magictrackpointd 2>&1"
	on error errText
		display dialog "MagicTrackpoint was not installed." & return & return & my lastLines(errText) ¬
			buttons {"OK"} default button "OK" with icon stop with title appTitle
		return
	end try

	set msg to "MagicTrackpoint is installed and running." & return & return & ¬
		"It needs two macOS permissions: Input Monitoring and Accessibility. Click Continue: System Settings opens on the right page."
	repeat
		activate
		set answer to button returned of (display dialog msg buttons {"Later", "Continue"} ¬
			default button "Continue" with title appTitle)
		if answer is "Later" then
			display dialog "You can grant them later. In Terminal, run:" & return & return & ¬
				"~/.local/bin/magictrackpointctl permissions" ¬
				buttons {"OK"} default button "OK" with title appTitle
			return
		end if
		try
			-- Restarts the daemon (Input Monitoring only takes effect after a
			-- restart), reports both permissions, opens the first missing pane.
			-- Exit status 3: a permission is still missing.
			do shell script quoted form of ctl & " permissions 2>&1"
			activate
			display dialog "All permissions granted. MagicTrackpoint is working." & return & return & ¬
				"You can eject the disk image. Settings and commands: ~/.local/bin/magictrackpointctl help" ¬
				buttons {"OK"} default button "OK" with title appTitle
			return
		on error errText number errNum
			if errNum is not 3 then
				activate
				display dialog "Could not check the permissions." & return & return & my lastLines(errText) ¬
					buttons {"OK"} default button "OK" with icon stop with title appTitle
				return
			end if
		end try
		set msg to "A permission is still missing (" & my missingName(errText) & ")." & return & return & ¬
			"In System Settings, turn on “magictrackpointd”. If it is not listed, click +, press Cmd+Shift+G, type:" & return & ¬
			daemon & return & "then Return and Open." & return & return & ¬
			"Then click Continue to check again."
	end repeat
end run

on missingName(t)
	repeat with p in paragraphs of t
		if p starts with "System Settings is open on " then
			set s to text 28 thru -1 of p
			set AppleScript's text item delimiters to ":"
			set n to text item 1 of s
			set AppleScript's text item delimiters to ""
			return n
		end if
	end repeat
	return "Input Monitoring or Accessibility"
end missingName

on lastLines(t)
	set ps to paragraphs of t
	set n to count of ps
	if n > 8 then set ps to items (n - 7) thru n of ps
	set AppleScript's text item delimiters to return
	set r to ps as text
	set AppleScript's text item delimiters to ""
	return r
end lastLines
