//
//  kanzenSettings.swift
//  Luna
//
//  Created by Dawud Osman on 17/11/2025.
//
//
//  SettingsView.swift
//  Kanzen
//
//  Created by Dawud Osman on 16/05/2025.
//
import SwiftUI

#if !os(tvOS)
struct KanzenSettingsView : View
{
    @EnvironmentObject var moduleManager: ModuleManager
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    @State private var autoUpdateModules = ModuleManager.isAutoUpdateEnabled
    @AppStorage("kanzenAutoMode") private var autoModeEnabled: Bool = false
    var body: some View
    {
        NavigationView {
            Form {
                Section(header: Text("General")) {
                    NavigationLink(destination: KanzenGeneralSettingsView()){Text("Preferences")}
                    NavigationLink(destination: MangaCatalogSettingsView()) {
                        Text("Home Catalogs")
                    }
                }
                .background(LunaScrollTracker())
                Section(header: Text("Modules"), footer: Text("Auto Mode will automatically search all modules and pick the best match when you tap a manga. This isn't fully reliable due to the vast amount of media — title variations across languages and regions can cause mismatches.")) {
                    NavigationLink(destination: KanzenModuleView().environmentObject(moduleManager)) {
                        Text("Manage Modules")
                    }
                    Toggle("Auto-Update Modules", isOn: $autoUpdateModules)
                        .onChange(of: autoUpdateModules) { newValue in
                            ModuleManager.isAutoUpdateEnabled = newValue
                        }
                    Toggle("Auto Mode", isOn: $autoModeEnabled)
                }
                Section(header: Text("Activity")) {
                    NavigationLink(destination: LoggerView()) {
                        Text("Logs")
                        
                    }
                    
                }
                Section(header: Text("Others")){
                    Text("Switch to Eclipse")
                        .onTapGesture {
                            showKanzen = false
                        }
                }
            }.navigationTitle("Settings")
    .lunaSettingsStyle()
        }
    }
}
#endif
