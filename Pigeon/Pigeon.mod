<?xml version="1.0" encoding="UTF-8"?>
<ModuleFile xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <UiMod name="Pigeon" version="1.1" date="11/01/2026">
    <Author name="Silkybottom" />
    <Description text="Pigeon: leader-to-leader messages and orders for warband leaders, with map pins and Warband Lead Helper voice relay." />
    <VersionSettings gameVersion="1.4.8" windowsVersion="0.1" />
    <Dependencies>
      <Dependency name="EA_ChatWindow" />
      <Dependency name="LibSlash" optional="false" forceEnable="true" />
      <!-- Optional bridges. Listed so they load before Pigeon when installed; Pigeon works without them. -->
      <Dependency name="MapMonster" optional="true" forceEnable="false" />
      <Dependency name="WARCommander" optional="true" forceEnable="false" />
      <Dependency name="wbLeadHelper" optional="true" forceEnable="false" />
      <Dependency name="ZonepopLite" optional="true" forceEnable="false" />
    </Dependencies>
    <Files>
      <File name="Pigeon.xml" />
      <File name="PigeonPlaces.lua" />
      <File name="Pigeon.lua" />
      <File name="PigeonLinks.lua" />
      <File name="PigeonMap.lua" />
      <File name="PigeonUI.lua" />
      <File name="PigeonBar.lua" />
    </Files>
    <OnInitialize>
      <CallFunction name="Pigeon.Initialize" />
    </OnInitialize>
    <OnUpdate>
      <CallFunction name="Pigeon.OnUpdate" />
    </OnUpdate>
    <OnShutdown>
      <CallFunction name="Pigeon.Shutdown" />
    </OnShutdown>
    <SavedVariables>
      <SavedVariable name="Pigeon.Saved" global="false" />
    </SavedVariables>
  </UiMod>
</ModuleFile>
