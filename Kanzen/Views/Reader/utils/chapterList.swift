//
//  chapterList.swift
//  Kanzen
//
//  Created by Dawud Osman on 09/10/2025.
//

import SwiftUI

struct ChapterList: View {
    @ObservedObject var readerManager: readerManager
    @EnvironmentObject var settings : Settings
    @State var reverseChapterlist: Bool = false

    var body: some View {
        ScrollView {
            VStack{
                if let chapters = readerManager.chapters {
                    var displayedChapters: Array<EnumeratedSequence<[Chapter]>.Element> {
                        if reverseChapterlist {
                            Array(chapters.enumerated().reversed())
                        } else {
                            Array(chapters.enumerated())
                        }
                    }

                    HStack{
                        Text("\(chapters.count) Chapters")
                            .font(.headline)
                            .bold()
                            .foregroundColor(settings.accentColor)
                        Spacer()
                        Image(systemName: "line.3.horizontal.decrease")
                            .renderingMode(.template)
                            .foregroundColor(settings.accentColor)
                            .padding(.leading,20)
                            .font(.title2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                reverseChapterlist.toggle()
                            }

                    }
                    Divider()
                    ForEach(displayedChapters, id:\.offset) { index, item in
                        if let chapterData = item.chapterData {
                            let isRead = readerManager.mangaId != 0 && MangaReadingProgressManager.shared.isChapterRead(
                                mangaId: readerManager.mangaId,
                                chapterNumber: item.chapterNumber
                            )
                            Button
                            {
                                DispatchQueue.main.async {
                                    readerManager.selectedChapter = item
                                    readerManager.resetState()
                                }
                            }label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.chapterNumber)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(isRead ? .secondary : settings.accentColor)
                                        .lineLimit(1)

                                    HStack {
                                        if chapterData.count > 0, !chapterData[0].scanlationGroup.isEmpty {
                                            Text(chapterData[0].scanlationGroup)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if isRead {
                                            Text("Read")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .opacity(isRead ? 0.6 : 1.0)
                            }
                        }
                        Divider()
                    }
                }
            }
        }.padding(10)
    }
}
