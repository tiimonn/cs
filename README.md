## Config

Go to

```
...\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg
```

```
D:\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg
```

```
code "D:\SteamLibrary\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg\autoexec.cfg"
```

and create a file called `autoexec.cfg`

## Launch Options

`-exec autoexec -console -high -full -novid -tickrate 128`

## Video Settings

```
C:\Program Files\Steam\userdata\164219666\730\local\cfg

code "C:\Program Files\Steam\userdata\164219666\730\local\cfg\cs2_video.txt"
```

`"setting.fullscreen_min_on_focus_loss"		"0"`

After that, set the file to readonly

```
(Get-Item "C:\Program Files\Steam\userdata\164219666\730\local\cfg\cs2_video.txt").IsReadOnly

Get-Item "C:\Program Files\Steam\userdata\164219666\730\local\cfg\cs2_video.txt" | Select-Object Name, IsReadOnly, Mode


Set-ItemProperty -Path "C:\Program Files\Steam\userdata\164219666\730\local\cfg\cs2_video.txt" -Name IsReadOnly -Value $true

Set-ItemProperty -Path "C:\Program Files\Steam\userdata\164219666\730\local\cfg\cs2_video.txt" -Name IsReadOnly -Value $false
```

---

## Resources

[Scancodes](https://totalcsgo.com/binds/converter)

[Bind](https://developer.valvesoftware.com/wiki/Bind)

PageUp scancode75
PageDown scancode78
