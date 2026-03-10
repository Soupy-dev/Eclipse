//
//  pageData.swift
//  Luna
//
//  Created by Dawud Osman on 17/11/2025.
//
//
//  pageData.swift
//  Kanzen
//
//  Created by Dawud Osman on 15/07/2025.
//
import SwiftUI
import Foundation
import Kingfisher
enum ChapterPosition
{
    case prev
    case curr
    case next
}

struct PageData: Identifiable, Equatable {
    let id: UUID = UUID()
    let content: String
    init (content:String)
    {
        
        self.content = content
    }
    
    var body:  chapterView {
        chapterView(page: self, index: "0")
    }
    static func == (lhs: PageData, rhs: PageData) -> Bool {
        lhs.id == rhs.id
    }
        
    
}
struct Chapters: Identifiable
{
    let id: UUID = UUID()
    let language: String
    var chapters: [Chapter]
}
struct Chapter: Identifiable
{
    let id: UUID = UUID()
    let chapterNumber: String
    let idx: Int
    let chapterData: [ ChapterData]?
}
struct ChapterData: Identifiable
{
    let id: UUID = UUID()
    var scanlationGroup: String = ""
    var title: String = ""
    let params: Any?
    init?(dict: [String:Any])
    {
        // Kanzen format: requires scanlation_group and id
        if let scanlationGroup = dict["scanlation_group"] as? String, let params = dict["id"] {
            self.scanlationGroup = scanlationGroup
            self.params = params
            self.title = dict["title"] as? String ?? ""
            return
        }
        // Sora format: uses href as params
        if let href = dict["href"] as? String {
            self.params = href
            self.title = dict["title"] as? String ?? ""
            self.scanlationGroup = ""
            return
        }
        return nil
    }
}



struct chapterView: View {
    let page: PageData
    let index: String

    var body: some View {
        if page.content == "CHAPTER_END" {
            Text("Chapter \(index) End")
                .frame(maxWidth: .infinity)
                .clipped()
        } else {
            if let url = URL(string: page.content) {
                KFImage(url)
                    .placeholder {
                        CircularLoader()
                    }
                    .resizable()
                    .scaledToFit()
                    .frame(width: UIScreen.main.bounds.width)
                    .background(Color.black)
            }
        }
    }
}

// MARK: - Zoomable Image View for Paged Reader

struct ZoomablePageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        // Load image with Kingfisher
        imageView.kf.setImage(with: url)

        // Double-tap gesture
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let location = gesture.location(in: imageView)
                let rect = CGRect(x: location.x - 50, y: location.y - 50, width: 100, height: 100)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

struct TransitionPage: View {
    var index: String
    var body: some View {
        Text("Chapter \(index) End")
            .frame(maxWidth: .infinity)
            .clipped()
    }
}
