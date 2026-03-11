//
//  readerManagerView.swift
//  Kanzen
//
//  Created by Dawud Osman on 13/06/2025.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
struct readerManagerView:View {
    @State  var chapters: [Chapter]?
    @State var selectedChapter: Chapter?
    @ObservedObject var kanzen : KanzenEngine
    @EnvironmentObject var settings : Settings
    @Environment(\.dismiss) var dismiss
    @State private var showFullScreen = true
    @State private var showChapterlist: Bool = false
    @State private var showReadingModePicker = false
    @State private var orientationLocked = false
    // new Implementation
    
    @StateObject   var reader_manager: readerManager
    init (chapters: [Chapter]?,selectedChapter: Chapter?,kanzen: KanzenEngine, mangaId: Int = 0, mangaTitle: String = "", mangaCoverURL: String = "")
    {
        self.kanzen = kanzen
        _reader_manager =  StateObject(wrappedValue: readerManager(kanzen:kanzen,chapters: chapters,selectedChapter: selectedChapter, mangaId: mangaId, mangaTitle: mangaTitle, mangaCoverURL: mangaCoverURL))
        _chapters = State(initialValue: chapters)
        _selectedChapter = State(initialValue: selectedChapter)
    }
    
    var body: some View {
        ZStack {
            // Custom Back Button
            
            //pageReader(reader_manager: reader_manager)
            
            //ScrollView{LazyVStack{ForEach(reader_manager.currChapter) { chapter in chapter.body}}}
            if(reader_manager.currChapter.count > 0)
            {
                readerContent()
            }
            else{
                CircularLoader()
            }
            readerOverlay()
        }
        
        .sheet(isPresented: $showChapterlist)
        {
            ChapterList(readerManager:  reader_manager)
        }
        .sheet(isPresented: $showReadingModePicker){
            readerManagerSettings(readerManager: reader_manager)
            //.presentationDetents([.fraction(0.3)]) // 👈 make it short (30% screen height)
            //.presentationCornerRadius(24) // 👈 curved top corners
            //.presentationBackground(.regularMaterial) // 👈 blurred material background
            
        }
        .onDisappear {
            AppDelegate.orientationLock = .all
        }
        .navigationBarBackButtonHidden(true)
        .task {
            reader_manager.initChapters()
        }
    }
    
    @ViewBuilder
    func readerContent() -> some View {
        switch(reader_manager.readingMode){
        case .LTR: pageReader(reader_manager: reader_manager, pageViewConfig: .LTR).id("LTR").onTapGesture {
            showFullScreen.toggle()
        }
        case .WEBTOON: WebtoonView(reader_manager: reader_manager).id("WEBTOON").onTapGesture {
            showFullScreen.toggle()
        }
        case .RTL: pageReader(reader_manager: reader_manager,pageViewConfig: .RTL).id("RTL").onTapGesture {
            showFullScreen.toggle()
        }
        case .VERTICAL: pageReader(reader_manager: reader_manager,pageViewConfig: .Vertical).id("VERTICAL").onTapGesture {
            showFullScreen.toggle()
        }
            
        }
        
    }
    
    @ViewBuilder
    func readerOverlay() -> some View {
        if showFullScreen {
            VStack(spacing: 0) {
                // MARK: - Top Bar
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        if !reader_manager.mangaTitle.isEmpty {
                            Text(reader_manager.mangaTitle)
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        Text(reader_manager.selectedChapter?.chapterNumber ?? "")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        AppDelegate.orientationLock = .all
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.bold())
                            .foregroundColor(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.top, 4)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0.7), Color.black.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(.all, edges: .top)
                )

                Spacer()

                // MARK: - Bottom Bar
                HStack(spacing: 20) {
                    // Orientation lock
                    Button {
                        toggleOrientationLock()
                    } label: {
                        Image(systemName: orientationLocked ? "lock.fill" : "lock.open")
                            .font(.title2)
                            .foregroundColor(orientationLocked ? settings.accentColor : .white)
                    }

                    // Settings
                    Button {
                        showReadingModePicker = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                    }

                    // Chapter list
                    Button {
                        showChapterlist = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundColor(.white)
                    }

                    Spacer()

                    // Page counter with chapter arrows
                    HStack(spacing: 10) {
                        Button {
                            reader_manager.goToPreviousChapter()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.callout.bold())
                                .foregroundColor(reader_manager.selectedChapter?.idx ?? 0 > 0 ? .white : .white.opacity(0.3))
                        }
                        .disabled(reader_manager.selectedChapter?.idx == 0)

                        Text("\(min(reader_manager.index + 1, max(reader_manager.currChapter.count, 1))) of \(max(reader_manager.currChapter.count, 1))")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .monospacedDigit()

                        Button {
                            reader_manager.goToNextChapter()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.callout.bold())
                                .foregroundColor((reader_manager.selectedChapter?.idx ?? 0) < (reader_manager.chapters?.count ?? 1) - 1 ? .white : .white.opacity(0.3))
                        }
                        .disabled(reader_manager.selectedChapter?.idx == (reader_manager.chapters?.count ?? 1) - 1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.10))
                    .cornerRadius(20)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 4)
                .background(
                    LinearGradient(
                        colors: [Color.black.opacity(0), Color.black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(.all, edges: .bottom)
                )
            }
        }
    }

    private func toggleOrientationLock() {
        orientationLocked.toggle()
        if orientationLocked {
            if #available(iOS 16.0, *) {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                let orientation = windowScene.interfaceOrientation
                let mask: UIInterfaceOrientationMask = orientation.isPortrait ? .portrait : .landscape
                AppDelegate.orientationLock = mask
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            } else {
                AppDelegate.orientationLock = .portrait
            }
        } else {
            AppDelegate.orientationLock = .all
            if #available(iOS 16.0, *) {
                guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .all))
            }
        }
    }
}
#endif
