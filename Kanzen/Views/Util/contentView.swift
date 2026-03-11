//
//  contentView.swift
//  Kanzen
//
//  Created by Dawud Osman on 27/05/2025.
//

import SwiftUI
import Foundation
import Kingfisher

#if !os(tvOS)
struct contentView: View {
    @State var parentModule: ModuleDataContainer?
    @State  var title: String
    @State  var imageURL: String
    @State  var params: String
    @State var expandedDescription : Bool = false
    @State private var contentData: [String:Any]?
    @State private var contentChapters: [Chapters]?
    @EnvironmentObject var kanzen: KanzenEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var favouriteManager : FavouriteManager
    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared
    @State private var showAddToCollection: Bool = false
    @State private var width: CGFloat = 150
    @State private var langaugeIdx: Int = 0
    @State private var showChaptersMenu: Bool = false
    @State private var selectedChapterData: Chapter? = nil
    @State private var selectedChapterIdx: Int?
    @State var reverseChapterlist: Bool = false
    @State var toggleFavourite: Bool = false
    @State var loadingState : Bool = true

    /// Stable numeric ID derived from module + content params for progress & library.
    private var stableId: Int {
        guard let module = parentModule else { return 0 }
        let combined = "\(module.id.uuidString):\(params)"
        let hash = combined.utf8.reduce(into: 5381) { h, c in h = ((h &<< 5) &+ h) &+ Int(c) }
        return hash < 0 ? hash : -hash - 1
    }

    private var libraryItem: MangaLibraryItem {
        MangaLibraryItem.fromModule(
            moduleId: parentModule?.id ?? UUID(),
            contentId: params,
            title: title,
            coverURL: imageURL,
            isNovel: parentModule?.moduleData.novel == true
        )
    }
    
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                if let contentData = contentData,
                   let description = contentData["description"] as? String, !description.isEmpty {
                    descriptionSection(description)
                    Divider()
                }

                if let contentData = contentData,
                   let tags = contentData["tags"] as? [String], !tags.isEmpty {
                    tagsSection(tags)
                    Divider()
                }

                if loadingState {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading chapters…")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    chaptersView()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .onAppear {
            getContentData()
            toggleFavourite = checkIfFavorited()
        }
        .fullScreenCover(item: $selectedChapterData, onDismiss: {
            if let chapter = selectedChapterData {
                progressManager.markChapterRead(
                    mangaId: stableId,
                    chapterNumber: chapter.chapterNumber,
                    mangaTitle: title,
                    coverURL: imageURL,
                    moduleUUID: parentModule?.id.uuidString,
                    contentParams: params,
                    isNovel: parentModule?.moduleData.novel == true
                )
            }
        }){ chapter in
            if let contentChapters = self.contentChapters{
                let chapterList = contentChapters[langaugeIdx].chapters
                if parentModule?.moduleData.novel == true {
                    NovelReaderView(
                        kanzen: kanzen,
                        chapters: chapterList,
                        initialChapter: chapter,
                        mangaId: stableId,
                        mangaTitle: title,
                        mangaCoverURL: imageURL
                    )
                } else {
                    readerManagerView(
                        chapters: chapterList,
                        selectedChapter: chapter,
                        kanzen: kanzen,
                        mangaId: stableId,
                        mangaTitle: title,
                        mangaCoverURL: imageURL
                    )
                }
            }
            
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(LunaTheme.shared.backgroundBase.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddToCollection = true
                } label: {
                    Image(systemName: libraryManager.isBookmarked(libraryItem) ? "bookmark.fill" : "bookmark")
                }
            }
        }
        .sheet(isPresented: $showAddToCollection) {
            MangaAddToCollectionView(item: libraryItem)
                .environmentObject(libraryManager)
        }
    }
    
    func checkIfFavorited() -> Bool {
        if let module = parentModule {
            return FavouriteManager.shared.isFavourite(moduleId: module.id, contentId: params)
        }
        return false
    }
    
    func getContentData() {
        kanzen.extractDetails(params: self.params) { result in
            DispatchQueue.main.async { self.contentData = result }
        }
        kanzen.extractChapters(params: self.params) { result in
            DispatchQueue.main.async {
                if let result = result {
                    var temp: [Chapters] = []

                    if let dictResult = result as? [String: Any] {
                        for (key, value) in dictResult {
                            var tempChapters: [Chapter] = []
                            if let chapters = value as? [Any?] {
                                for (idx, chapter) in chapters.enumerated() {
                                    if let chapter = chapter as? [Any?], let chapterName = chapter[0] as? String, let rawData = chapter[1] as? [[String: Any?]], let chapterData = rawData.compactMap({ChapterData(dict: $0 as [String : Any])}) as? [ChapterData] {
                                        tempChapters.append(Chapter(chapterNumber: chapterName, idx: idx, chapterData: chapterData))
                                    }
                                }
                            }
                            if !tempChapters.isEmpty {
                                temp.append(Chapters(language: key, chapters: tempChapters))
                            }
                        }
                    } else if let arrResult = result as? [[String: Any]] {
                        var tempChapters: [Chapter] = []
                        for (idx, chapterDict) in arrResult.enumerated() {
                            let name = (chapterDict["number"] as? Int).map { "Chapter \($0)" }
                                ?? (chapterDict["title"] as? String)
                                ?? "Chapter \(idx + 1)"
                            if let data = ChapterData(dict: chapterDict) {
                                tempChapters.append(Chapter(chapterNumber: name, idx: idx, chapterData: [data]))
                            }
                        }
                        if !tempChapters.isEmpty {
                            temp.append(Chapters(language: "default", chapters: tempChapters))
                        }
                    }

                    self.contentChapters = temp
                }
                self.loadingState = false
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            KFImage(URL(string: imageURL))
                .placeholder { ProgressView() }
                .resizable()
                .scaledToFill()
                .frame(width: width, height: width * 1.5)
                .clipped()
                .cornerRadius(16)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(3)

                if parentModule?.moduleData.novel == true {
                    Text("Light Novel")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                } else {
                    Text("Manga")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }

                if let contentData = contentData {
                    if let status = contentData["status"] as? String {
                        Label(status, systemImage: "clock.arrow.circlepath")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if let authorArtist = contentData["authorArtist"] as? [String], !authorArtist.isEmpty {
                        Text(authorArtist.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                if let parentModule = parentModule {
                    Label(parentModule.moduleData.sourceName, systemImage: "puzzlepiece.extension")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Description

    @ViewBuilder
    private func descriptionSection(_ text: String) -> some View {
        let cleaned = text
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        VStack(alignment: .leading, spacing: 4) {
            Text("Synopsis")
                .font(.headline)

            Text(cleaned)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(expandedDescription ? nil : 4)
                .onTapGesture {
                    withAnimation { expandedDescription.toggle() }
                }

            if !expandedDescription {
                Text("Show more")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .onTapGesture {
                        withAnimation { expandedDescription.toggle() }
                    }
            }
        }
    }

    // MARK: - Tags

    @ViewBuilder
    private func tagsSection(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Chapters

    @ViewBuilder
    func chaptersView() -> some View {
        if let chaptersData = self.contentChapters, !chaptersData.isEmpty {
            let selected = chaptersData[langaugeIdx]
            let displayed: [Chapter] = reverseChapterlist ? selected.chapters.reversed() : selected.chapters

            VStack(alignment: .leading, spacing: 0) {
                readButton(chapters: selected.chapters)
                    .padding(.bottom, 8)

                HStack {
                    Text("\(selected.chapters.count) Chapters")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Spacer()

                    if chaptersData.count > 1 {
                        Menu {
                            ForEach(Array(chaptersData.enumerated()), id: \.offset) { idx, lang in
                                Button(lang.language) { langaugeIdx = idx }
                            }
                        } label: {
                            Image(systemName: "globe")
                                .foregroundColor(.accentColor)
                        }
                    }

                    Button {
                        reverseChapterlist.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundColor(.accentColor)
                    }
                }

                Divider().padding(.vertical, 4)

                ForEach(displayed) { chapter in
                    let isRead = progressManager.isChapterRead(mangaId: stableId, chapterNumber: chapter.chapterNumber)
                    let chapterTitle = chapter.chapterData?.first?.title ?? ""

                    Button {
                        selectedChapterData = chapter
                    } label: {
                        HStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 3) {
                                if !chapterTitle.isEmpty {
                                    Text(chapter.chapterNumber)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(isRead ? .secondary : .primary)
                                        .lineLimit(1)
                                    Text(chapterTitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text(chapter.chapterNumber)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(isRead ? .secondary : .primary)
                                        .lineLimit(1)
                                }

                                if let data = chapter.chapterData, let first = data.first, !first.scanlationGroup.isEmpty {
                                    Text(first.scanlationGroup)
                                        .font(.caption2)
                                        .foregroundColor(.accentColor.opacity(0.8))
                                        .lineLimit(1)
                                }
                            }

                            Spacer(minLength: 8)

                            if isRead {
                                Text("Read")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .opacity(isRead ? 0.6 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if isRead {
                            Button {
                                progressManager.markChapterUnread(mangaId: stableId, chapterNumber: chapter.chapterNumber)
                            } label: {
                                Label("Mark as Unread", systemImage: "eye.slash")
                            }
                        } else {
                            Button {
                                progressManager.markChapterRead(mangaId: stableId, chapterNumber: chapter.chapterNumber, mangaTitle: title, coverURL: imageURL, moduleUUID: parentModule?.id.uuidString, contentParams: params, isNovel: parentModule?.moduleData.novel == true)
                            } label: {
                                Label("Mark as Read", systemImage: "eye")
                            }
                        }

                        Divider()

                        Button {
                            let allNums = selected.chapters.map { $0.chapterNumber }
                            if let idx = allNums.firstIndex(of: chapter.chapterNumber) {
                                let toMark = Array(allNums[...idx])
                                progressManager.markAllRead(mangaId: stableId, chapterNumbers: toMark)
                            }
                        } label: {
                            Label("Mark This & Previous as Read", systemImage: "checkmark.circle")
                        }

                        Button {
                            let allNums = selected.chapters.map { $0.chapterNumber }
                            progressManager.markAllRead(mangaId: stableId, chapterNumbers: allNums)
                        } label: {
                            Label("Mark All as Read", systemImage: "checkmark.circle.fill")
                        }

                        Button(role: .destructive) {
                            progressManager.markAllUnread(mangaId: stableId)
                        } label: {
                            Label("Mark All as Unread", systemImage: "xmark.circle")
                        }
                    }
                    Divider()
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("No chapters found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Read / Continue Button

    @ViewBuilder
    private func readButton(chapters: [Chapter]) -> some View {
        let lastRead = progressManager.lastReadChapter(for: stableId)
        let hasProgress = lastRead != nil

        let targetChapter: Chapter? = {
            if let lastRead = lastRead {
                if let ch = chapters.first(where: { $0.chapterNumber == lastRead }) {
                    return ch
                }
            }
            return chapters.first
        }()

        if let target = targetChapter {
            Button {
                selectedChapterData = target
            } label: {
                HStack {
                    Image(systemName: hasProgress ? "book.fill" : "play.fill")
                        .font(.subheadline)
                    Text(hasProgress ? "Continue Reading" : "Start Reading")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundColor(.white)
                .background(Color.accentColor)
                .cornerRadius(16)
            }
            .buttonStyle(.plain)
        }
    }
}
#endif
