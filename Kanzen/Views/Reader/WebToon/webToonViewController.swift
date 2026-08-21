//
//  WebtoonView.swift
//  Kanzen
//
//  Created by Dawud Osman on 01/09/2025.
//

import SwiftUI
import UIKit
import QuartzCore
import ImageIO
import CoreImage
import Nuke
import AsyncDisplayKit
#if canImport(CoreML) && canImport(Vision)
import CoreML
import Vision
#endif
#if canImport(VisionKit)
import VisionKit
#endif

private func kanzenReaderCanvasColor(for style: UIUserInterfaceStyle) -> UIColor {
    switch ProfileSettingsStore.active.string(forKey: "Reader.backgroundColor") {
    case "white":
        return .white
    case "system":
        return .systemBackground
    case "auto":
        return style == .dark ? .black : .white
    default:
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return UIColor(red: 0.055, green: 0.050, blue: 0.090, alpha: 1)
        }
        return .black
    }
}

private func kanzenReaderAnimatesPageTransitions() -> Bool {
    if ProfileSettingsStore.active.object(forKey: "Reader.animatePageTransitions") == nil {
        return true
    }
    return ProfileSettingsStore.active.bool(forKey: "Reader.animatePageTransitions")
}

struct WebtoonView: UIViewControllerRepresentable {
    let reader_manager: readerManager
    var onPageChanged: (Int) -> Void = { _ in }
    var onTap: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(reader_manager: reader_manager, onPageChanged: onPageChanged, onTap: onTap)
    }

    func makeUIViewController(context: Context) -> WebtoonReaderViewController {
        let layout = WebtoonOffsetPreservingLayout()
        let viewController = WebtoonReaderViewController(layout: layout)
        let containerView = viewController.containerView
        let collectionNode = containerView.collectionNode
        let collectionView = collectionNode.view
        layout.fallbackHeightProvider = { [weak coordinator = context.coordinator] indexPath, width in
            coordinator?.estimatedHeight(for: indexPath.item, width: width) ?? max(320, width * Coordinator.defaultImageAspectRatio)
        }
        let canvasColor = kanzenReaderCanvasColor(for: viewController.traitCollection.userInterfaceStyle)
        collectionNode.backgroundColor = canvasColor
        collectionNode.dataSource = context.coordinator
        collectionNode.delegate = context.coordinator
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .minimum, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .minimum, rangeType: .preload)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .lowMemory, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .lowMemory, rangeType: .preload)
        collectionNode.contentInset = .zero
        collectionNode.showsVerticalScrollIndicator = false
        collectionNode.showsHorizontalScrollIndicator = false
        collectionNode.automaticallyManagesSubnodes = true
        collectionNode.shouldAnimateSizeChanges = false
        collectionNode.insetsLayoutMarginsFromSafeArea = false
        collectionView.backgroundColor = canvasColor
        collectionView.isPagingEnabled = false
        collectionView.bounces = false
        collectionView.alwaysBounceVertical = false
        collectionView.scrollsToTop = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.scrollIndicatorInsets = .zero
        collectionView.delaysContentTouches = false
        if #available(iOS 11.0, *) {
            collectionView.contentInsetAdjustmentBehavior = .never
        }
        containerView.onLayout = { [weak coordinator = context.coordinator, weak collectionNode] in
            guard let collectionNode else { return }
            coordinator?.collectionNodeDidLayout(collectionNode)
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        collectionView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        pinch.delegate = context.coordinator
        collectionView.addGestureRecognizer(pinch)

        context.coordinator.collectionNode = collectionNode
        return viewController
    }

    func updateUIViewController(_ uiViewController: WebtoonReaderViewController, context: Context) {
        context.coordinator.reader_manager = reader_manager
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onTap = onTap
        context.coordinator.configure(uiViewController.containerView.collectionNode, manager: reader_manager)
    }

    static func dismantleUIViewController(_ uiViewController: WebtoonReaderViewController, coordinator: Coordinator) {
        coordinator.stopPerfMonitoring()
        coordinator.cancelWork()
    }

    final class Coordinator: NSObject, ASCollectionDataSource, ASCollectionDelegate, UIGestureRecognizerDelegate {
        var reader_manager: readerManager
        var onPageChanged: (Int) -> Void
        var onTap: () -> Void
        weak var collectionNode: ASCollectionNode?

        private var pages: [PageData] = []
        private var pagesSignature = ""
        private var recentImageRatios: [CGFloat] = []
        private var chapterIdentity = ""
        private var lastKnownWidth: CGFloat = 0
        private var loadingPrevious = false
        private var loadingNext = false
        private var lastReportedPage = -1
        private var pendingLayoutWorkItem: DispatchWorkItem?
        private var pendingScrollToPage: Int?
        private var didInitialPosition = false
        private var needsDeferredLayoutUpdate = false
        private var displayLink: CADisplayLink?
        private var lastDisplayTimestamp: CFTimeInterval?
        private var lastHitchLogTime = Date.distantPast
        private var lastScrollLogTime = Date.distantPast
        private var pendingScrollRetryScheduled = false
        private var pinchStartScale: CGFloat = 1

        fileprivate static let defaultImageAspectRatio: CGFloat = 1.435

        init(reader_manager: readerManager, onPageChanged: @escaping (Int) -> Void, onTap: @escaping () -> Void) {
            self.reader_manager = reader_manager
            self.onPageChanged = onPageChanged
            self.onTap = onTap
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onTap()
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            guard let collectionNode,
                  let layout = collectionNode.view.collectionViewLayout as? WebtoonOffsetPreservingLayout else { return }

            let collectionView = collectionNode.view
            switch gesture.state {
            case .began:
                pinchStartScale = layout.zoomScale
            case .changed, .ended:
                let nextScale = min(max(pinchStartScale * gesture.scale, 1), 5)
                setZoomScale(nextScale, in: collectionView, layout: layout, anchor: gesture.location(in: collectionView))
            case .cancelled, .failed:
                pinchStartScale = layout.zoomScale
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let current = view {
                if current is UIControl { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
        }

        func configure(_ collectionNode: ASCollectionNode, manager: readerManager) {
            (collectionNode.view.collectionViewLayout as? WebtoonOffsetPreservingLayout)?.fallbackHeightProvider = { [weak self] indexPath, width in
                self?.estimatedHeight(for: indexPath.item, width: width) ?? max(320, width * Self.defaultImageAspectRatio)
            }
            let identity = Self.identity(for: manager)
            let signature = Self.pagesSignature(for: manager.currChapter)
            let needsInitialBuild = pages.isEmpty && !manager.currChapter.isEmpty
            if needsInitialBuild || identity != chapterIdentity || signature != pagesSignature {
                reset(collectionNode, manager: manager, signature: signature)
            }

            if manager.changeIndex,
               manager.index >= 0,
               manager.index < pages.count {
                pendingScrollToPage = manager.index
                manager.changeIndex = false
                scrollToPendingPage(in: collectionNode)
            } else if !didInitialPosition, !pages.isEmpty {
                pendingScrollToPage = min(max(manager.index, 0), pages.count - 1)
                scrollToPendingPage(in: collectionNode)
            }
        }

        func collectionNodeDidLayout(_ collectionNode: ASCollectionNode) {
            let collectionView = collectionNode.view
            let width = max(collectionView.bounds.width, 1)
            if abs(width - lastKnownWidth) >= 1 {
                lastKnownWidth = width
                updateAllPageLayout(in: collectionNode, preserveCurrentPage: didInitialPosition)
            }
            scrollToPendingPage(in: collectionNode)
        }

        private func reset(_ collectionNode: ASCollectionNode, manager: readerManager, signature: String) {
            let collectionView = collectionNode.view
            cancelWork()
            pages = manager.currChapter
            pagesSignature = signature
            chapterIdentity = Self.identity(for: manager)
            recentImageRatios.removeAll()
            lastReportedPage = -1
            loadingPrevious = false
            loadingNext = false
            didInitialPosition = false
            pendingScrollRetryScheduled = false
            lastDisplayTimestamp = nil
            needsDeferredLayoutUpdate = false
            pendingScrollToPage = min(max(manager.index, 0), max(pages.count - 1, 0))

            let width = max(collectionView.bounds.width, lastKnownWidth, UIScreen.main.bounds.width, 1)
            lastKnownWidth = width
            if let layout = collectionView.collectionViewLayout as? WebtoonOffsetPreservingLayout {
                layout.zoomScale = 1
                layout.invalidateLayout()
            }

            ReaderLogger.shared.log(
                "Webtoon texture reset chapter=\(manager.selectedChapter?.chapterNumber ?? "<none>") pages=\(pages.count)",
                type: "ReaderWebtoon"
            )

            Task { @MainActor [weak self, weak collectionNode] in
                guard let self, let collectionNode else { return }
                await collectionNode.reloadData()
                collectionNode.view.layoutIfNeeded()
                self.scrollToPendingPage(in: collectionNode)
            }
        }

        func cancelWork() {
            pendingLayoutWorkItem?.cancel()
            pendingLayoutWorkItem = nil
            needsDeferredLayoutUpdate = false
            reader_manager.flushPendingPagePosition()
            collectionNode?.visibleNodes.compactMap { $0 as? WebtoonTexturePageNode }.forEach { $0.cancelLoad() }
        }

        func startPerfMonitoring() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopPerfMonitoring() {
            displayLink?.invalidate()
            displayLink = nil
            lastDisplayTimestamp = nil
        }

        @objc private func displayLinkTick(_ link: CADisplayLink) {
            guard let previous = lastDisplayTimestamp else {
                lastDisplayTimestamp = link.timestamp
                return
            }
            lastDisplayTimestamp = link.timestamp

            let deltaMs = (link.timestamp - previous) * 1000
            guard deltaMs >= 95 else { return }

            let now = Date()
            guard now.timeIntervalSince(lastHitchLogTime) >= 1.5 else { return }
            lastHitchLogTime = now

            let offset = Int(collectionNode?.contentOffset.y ?? 0)
            let contentHeight = Int(collectionNode?.view.contentSize.height ?? 0)
            let visible = collectionNode?.indexPathsForVisibleItems.map(\.item).sorted() ?? []
            ReaderLogger.shared.log(
                "Webtoon frame hitch deltaMs=\(Int(deltaMs)) page=\(lastReportedPage + 1)/\(pages.count) offset=\(offset)/\(contentHeight) visible=\(visible)",
                type: "ReaderPerf"
            )
        }

        func numberOfSections(in collectionNode: ASCollectionNode) -> Int {
            1
        }

        func collectionNode(_ collectionNode: ASCollectionNode, numberOfItemsInSection section: Int) -> Int {
            pages.count
        }

        func collectionNode(_ collectionNode: ASCollectionNode, nodeBlockForItemAt indexPath: IndexPath) -> ASCellNodeBlock {
            guard indexPath.item < pages.count else {
                return { ASCellNode() }
            }
            let page = pages[indexPath.item]
            let index = indexPath.item
            let targetSize = targetImageSize(for: collectionNode)
            let scale = collectionNode.view.window?.screen.scale ?? UIScreen.main.scale
            let estimatedRatio = estimatedImageAspectRatio()
            return { [weak self, weak collectionNode] in
                let node = WebtoonTexturePageNode(
                    page: page,
                    index: index,
                    targetSize: targetSize,
                    scale: scale,
                    estimatedRatio: estimatedRatio
                )
                node.onHeightChanged = { [weak self, weak collectionNode] page, size, index in
                    guard let self, let collectionNode else { return }
                    self.updatePageHeight(page: page, size: size, index: index, collectionView: collectionNode.view)
                }
                return node
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let collectionNode, !pages.isEmpty else { return }
            let collectionView = collectionNode.view
            updateCurrentPage(in: collectionView)
            loadAdjacentChaptersIfNeeded(collectionNode)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate, let collectionView = scrollView as? UICollectionView else { return }
            flushDeferredLayoutUpdate(in: collectionView)
            reader_manager.flushPendingPagePosition()
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            flushDeferredLayoutUpdate(in: collectionView)
            reader_manager.flushPendingPagePosition()
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView else { return }
            flushDeferredLayoutUpdate(in: collectionView)
            reader_manager.flushPendingPagePosition()
        }

        private func scrollToPendingPage(in collectionNode: ASCollectionNode) {
            guard let index = pendingScrollToPage,
                  index >= 0,
                  index < pages.count else { return }
            let collectionView = collectionNode.view
            collectionView.layoutIfNeeded()
            let indexPath = IndexPath(item: index, section: 0)

            guard collectionView.numberOfSections > 0 else {
                retryScrollToPendingPage(in: collectionNode)
                return
            }

            guard collectionView.numberOfItems(inSection: 0) > index else {
                retryScrollToPendingPage(in: collectionNode)
                return
            }

            collectionNode.scrollToItem(at: indexPath, at: .top, animated: false)
            pendingScrollRetryScheduled = false
            pendingScrollToPage = nil
            didInitialPosition = true
            updateCurrentPage(in: collectionView, force: true)
        }

        private func retryScrollToPendingPage(in collectionNode: ASCollectionNode) {
            guard !pendingScrollRetryScheduled else { return }
            pendingScrollRetryScheduled = true
            DispatchQueue.main.async { [weak self, weak collectionNode] in
                guard let self, let collectionNode else { return }
                self.pendingScrollRetryScheduled = false
                self.scrollToPendingPage(in: collectionNode)
            }
        }

        private func updateAllPageLayout(in collectionNode: ASCollectionNode, preserveCurrentPage: Bool) {
            let currentPage = preserveCurrentPage ? max(lastReportedPage, 0) : nil
            let collectionView = collectionNode.view
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            if let currentPage, currentPage < pages.count {
                pendingScrollToPage = currentPage
                scrollToPendingPage(in: collectionNode)
            }
        }

        private func updatePageHeight(
            page: PageData,
            size: CGSize?,
            index: Int,
            collectionView: UICollectionView
        ) {
            guard index < pages.count, pages[index].id == page.id else { return }
            if let size, size.width > 0, size.height > 0 {
                let ratio = size.height / size.width
                if ratio.isFinite {
                    recentImageRatios.append(ratio)
                    if recentImageRatios.count > 16 {
                        recentImageRatios.removeFirst(recentImageRatios.count - 16)
                    }
                }
            }

            guard let layout = collectionView.collectionViewLayout as? WebtoonOffsetPreservingLayout else { return }
            let width = max(collectionView.bounds.width, 1)
            let oldFrame = layout.frameForItem(at: index)
            let oldHeight = oldFrame?.height ?? estimatedHeight(for: index, width: width) * layout.zoomScale
            let newHeight: CGFloat
            if let size, size.width > 0, size.height > 0 {
                newHeight = max(1, width * (size.height / size.width)) * layout.zoomScale
            } else {
                newHeight = layout.heightForItem(at: IndexPath(item: index, section: 0), width: width) * layout.zoomScale
            }
            let delta = newHeight - oldHeight
            guard abs(delta) >= 1 else { return }

            let pageFrame = oldFrame ?? CGRect(x: 0, y: 0, width: collectionView.bounds.width * layout.zoomScale, height: oldHeight)
            let viewport = CGRect(
                x: 0,
                y: collectionView.contentOffset.y,
                width: max(collectionView.bounds.width, 1),
                height: collectionView.bounds.height
            )
            let wasAboveViewport = pageFrame.maxY <= collectionView.contentOffset.y + 1
            let isVisible = pageFrame.intersects(viewport)

            guard wasAboveViewport || isVisible else {
                scheduleLayoutUpdate(in: collectionView)
                return
            }

            guard wasAboveViewport || !shouldDeferLayoutUpdate(in: collectionView) else {
                scheduleLayoutUpdate(in: collectionView)
                return
            }

            UIView.performWithoutAnimation {
                layout.invalidateLayout()
                if wasAboveViewport {
                    let adjusted = CGPoint(
                        x: collectionView.contentOffset.x,
                        y: max(0, collectionView.contentOffset.y + delta)
                    )
                    collectionView.setContentOffset(adjusted, animated: false)
                }
            }
        }

        private func scheduleLayoutUpdate(in collectionView: UICollectionView) {
            pendingLayoutWorkItem?.cancel()
            guard !shouldDeferLayoutUpdate(in: collectionView) else {
                needsDeferredLayoutUpdate = true
                pendingLayoutWorkItem = nil
                return
            }
            let workItem = DispatchWorkItem { [weak collectionView] in
                guard let collectionView else { return }
                UIView.performWithoutAnimation {
                    collectionView.collectionViewLayout.invalidateLayout()
                }
            }
            pendingLayoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
        }

        private func flushDeferredLayoutUpdate(in collectionView: UICollectionView) {
            guard needsDeferredLayoutUpdate else { return }
            pendingLayoutWorkItem?.cancel()
            pendingLayoutWorkItem = nil
            needsDeferredLayoutUpdate = false
            UIView.performWithoutAnimation {
                collectionView.collectionViewLayout.invalidateLayout()
            }
        }

        private func shouldDeferLayoutUpdate(in collectionView: UICollectionView) -> Bool {
            collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        }

        fileprivate func estimatedHeight(for index: Int, width: CGFloat) -> CGFloat {
            guard index >= 0, index < pages.count else {
                return max(320, width * Self.defaultImageAspectRatio)
            }
            return estimatedHeight(for: pages[index], width: width)
        }

        private func estimatedHeight(for page: PageData, width: CGFloat) -> CGFloat {
            if let text = page.textContent {
                let constraint = CGSize(width: max(width - 48, 1), height: CGFloat.greatestFiniteMagnitude)
                let rect = (text as NSString).boundingRect(
                    with: constraint,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
                    context: nil
                )
                return max(320, ceil(rect.height) + 64)
            }
            return max(320, width * estimatedImageAspectRatio())
        }

        private func estimatedImageAspectRatio() -> CGFloat {
            let ratios = recentImageRatios
            guard !ratios.isEmpty else { return Self.defaultImageAspectRatio }

            let sorted = ratios.sorted()
            let median = sorted[sorted.count / 2]
            return min(max(median, 1.1), 6.0)
        }

        private func updateCurrentPage(in collectionView: UICollectionView, force: Bool = false) {
            guard !pages.isEmpty else { return }
            let midpoint = CGPoint(
                x: collectionView.contentOffset.x + collectionView.bounds.width * 0.5,
                y: collectionView.contentOffset.y + collectionView.bounds.height * 0.5
            )
            let visibleIndex = collectionView.indexPathForItem(at: midpoint)?.item
                ?? (collectionView.collectionViewLayout as? WebtoonOffsetPreservingLayout)?.indexForY(midpoint.y)
                ?? collectionView.indexPathsForVisibleItems.sorted().first?.item

            guard let visibleIndex, visibleIndex >= 0, visibleIndex < pages.count else { return }
            if force || lastReportedPage != visibleIndex {
                lastReportedPage = visibleIndex
                if force {
                    reader_manager.setIndex(visibleIndex)
                } else {
                    reader_manager.setTransientIndex(visibleIndex)
                }
                onPageChanged(visibleIndex)

                if force, Date().timeIntervalSince(lastScrollLogTime) > 2 {
                    lastScrollLogTime = Date()
                    ReaderLogger.shared.log("Webtoon current page=\(visibleIndex + 1)/\(pages.count)", type: "ReaderProgress")
                }
            }
        }

        private func targetImageSize(for collectionNode: ASCollectionNode) -> CGSize {
            let collectionView = collectionNode.view
            let zoomScale = (collectionView.collectionViewLayout as? WebtoonOffsetPreservingLayout)?.zoomScale ?? 1
            let viewportWidth = max(collectionView.bounds.width * zoomScale, 1)
            let viewportHeight = max(collectionView.bounds.height, viewportWidth * 1.45)
            return CGSize(width: viewportWidth, height: viewportHeight)
        }

        private func setZoomScale(
            _ scale: CGFloat,
            in collectionView: UICollectionView,
            layout: WebtoonOffsetPreservingLayout,
            anchor: CGPoint
        ) {
            let clamped = min(max(scale, 1), 5)
            guard abs(layout.zoomScale - clamped) >= 0.01 else { return }

            let oldContentSize = collectionView.contentSize
            let normalizedX = (collectionView.contentOffset.x + anchor.x) / max(oldContentSize.width, 1)
            let normalizedY = (collectionView.contentOffset.y + anchor.y) / max(oldContentSize.height, 1)

            layout.zoomScale = clamped
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()

            let maxOffsetX = max(collectionView.contentSize.width - collectionView.bounds.width, 0)
            let maxOffsetY = max(collectionView.contentSize.height - collectionView.bounds.height, 0)
            let nextOffset = CGPoint(
                x: min(max(normalizedX * collectionView.contentSize.width - anchor.x, 0), maxOffsetX),
                y: min(max(normalizedY * collectionView.contentSize.height - anchor.y, 0), maxOffsetY)
            )
            collectionView.setContentOffset(nextOffset, animated: false)
        }

        private func loadAdjacentChaptersIfNeeded(_ collectionNode: ASCollectionNode) {
            let collectionView = collectionNode.view
            let threshold = max(collectionView.bounds.height * 1.25, 420)
            let topDistance = collectionNode.contentOffset.y
            let bottomDistance = collectionView.contentSize.height - (collectionNode.contentOffset.y + collectionView.bounds.height)

            if topDistance < threshold {
                prependPreviousChapterIfNeeded()
            }
            if bottomDistance < threshold {
                appendNextChapterIfNeeded()
            }
        }

        private func prependPreviousChapterIfNeeded() {
            guard !loadingPrevious else { return }
            guard (reader_manager.selectedChapter?.idx ?? 0) > 0 else { return }
            guard reader_manager.prevChapter.isEmpty else { return }

            loadingPrevious = true
            reader_manager.fetchTask(bool: false) { [weak self] in
                DispatchQueue.main.async {
                    self?.loadingPrevious = false
                }
            }
        }

        private func appendNextChapterIfNeeded() {
            guard !loadingNext else { return }
            guard let selectedChapter = reader_manager.selectedChapter,
                  let allChapters = reader_manager.chapters,
                  selectedChapter.idx < allChapters.count - 1 else { return }
            guard reader_manager.nextChapter.isEmpty else { return }

            loadingNext = true
            reader_manager.fetchTask(bool: true) { [weak self] in
                DispatchQueue.main.async {
                    self?.loadingNext = false
                }
            }
        }

        private static func identity(for manager: readerManager) -> String {
            "\(manager.selectedChapter?.idx ?? -1):\(manager.selectedChapter?.chapterNumber ?? "")"
        }

        private static func pagesSignature(for pages: [PageData]) -> String {
            let first = pages.first?.cacheKey ?? ""
            let last = pages.last?.cacheKey ?? ""
            return "\(pages.count)|\(first)|\(last)"
        }
    }
}

final class WebtoonReaderViewController: UIViewController {
    let containerView: WebtoonTextureContainerView

    init(layout: UICollectionViewLayout) {
        self.containerView = WebtoonTextureContainerView(layout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = containerView
    }

    override var prefersStatusBarHidden: Bool {
        true
    }
}

final class WebtoonTextureContainerView: UIView {
    let collectionNode: ASCollectionNode
    var onLayout: (() -> Void)?

    init(layout: UICollectionViewLayout) {
        self.collectionNode = ASCollectionNode(collectionViewLayout: layout)
        super.init(frame: .zero)
        backgroundColor = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        collectionNode.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionNode.view)
        NSLayoutConstraint.activate([
            collectionNode.view.topAnchor.constraint(equalTo: topAnchor),
            collectionNode.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionNode.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionNode.view.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

private final class WebtoonTexturePageNode: ASCellNode {
    private enum RenderState {
        case loading
        case image
        case text
        case failure
    }

    let page: PageData
    let pageIndex: Int
    let targetSize: CGSize
    let scale: CGFloat
    let estimatedRatio: CGFloat
    var onHeightChanged: ((PageData, CGSize?, Int) -> Void)?

    private let imageNode = ASImageNode()
    private let textNode = ASTextNode()
    private let statusNode = ASTextNode()
    private let retryButtonNode = ASButtonNode()
    private var renderState: RenderState = .loading
    private var imageRatio: CGFloat?
    private var didAttemptLoad = false
    private var imageLoadTask: Task<Void, Never>?
    private var imageTask: ImageTask?

    init(
        page: PageData,
        index: Int,
        targetSize: CGSize,
        scale: CGFloat,
        estimatedRatio: CGFloat
    ) {
        self.page = page
        self.pageIndex = index
        self.targetSize = targetSize
        self.scale = scale
        self.estimatedRatio = estimatedRatio
        super.init()
        automaticallyManagesSubnodes = true
        shouldAnimateSizeChanges = false
        backgroundColor = kanzenReaderCanvasColor(for: .dark)

        imageNode.backgroundColor = kanzenReaderCanvasColor(for: .dark)
        imageNode.contentMode = .scaleToFill
        imageNode.isUserInteractionEnabled = false

        textNode.backgroundColor = kanzenReaderCanvasColor(for: .dark)
        textNode.maximumNumberOfLines = 0

        statusNode.attributedText = Self.statusText("Loading...")
        retryButtonNode.setAttributedTitle(Self.buttonText("Retry"), for: .normal)
        retryButtonNode.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        retryButtonNode.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        retryButtonNode.addTarget(self, action: #selector(retryTapped), forControlEvents: .touchUpInside)
    }

    deinit {
        cancelLoad()
    }

    override func didEnterPreloadState() {
        super.didEnterPreloadState()
        loadIfNeeded()
    }

    override func didEnterDisplayState() {
        super.didEnterDisplayState()
        loadIfNeeded()
    }

    override func didExitDisplayState() {
        super.didExitDisplayState()
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let ratio = max(imageRatio ?? estimatedRatio, 0.2)
        let child: ASLayoutElement

        switch renderState {
        case .image:
            child = imageNode
        case .text:
            let inset = ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24),
                child: textNode
            )
            child = inset
        case .failure:
            child = ASCenterLayoutSpec(
                horizontalPosition: .center,
                verticalPosition: .center,
                sizingOption: [],
                child: retryButtonNode
            )
        case .loading:
            child = ASCenterLayoutSpec(
                horizontalPosition: .center,
                verticalPosition: .center,
                sizingOption: [],
                child: statusNode
            )
        }

        return ASRatioLayoutSpec(ratio: ratio, child: child)
    }

    func cancelLoad() {
        imageTask?.cancel()
        imageLoadTask?.cancel()
        imageTask = nil
        imageLoadTask = nil
    }

    private func loadIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        if let text = page.textContent {
            textNode.attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.white
                ]
            )
            renderState = .text
            onHeightChanged?(page, nil, pageIndex)
            setNeedsLayout()
            return
        }

        guard page.isImageLike else {
            renderState = .failure
            onHeightChanged?(page, nil, pageIndex)
            setNeedsLayout()
            return
        }

        imageLoadTask?.cancel()
        imageTask?.cancel()
        renderState = .loading
        setNeedsLayout()

        imageLoadTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            do {
                let image = try await ReaderWebtoonImagePipeline.loadImage(
                    for: page,
                    targetSize: targetSize,
                    scale: scale,
                    taskSink: { [weak self] task in
                        Task { @MainActor in
                            self?.imageTask = task
                        }
                    }
                )
                await MainActor.run {
                    self.imageNode.image = image
                    self.imageRatio = image.size.width > 0 ? image.size.height / image.size.width : self.estimatedRatio
                    self.renderState = .image
                    self.onHeightChanged?(self.page, image.size, self.pageIndex)
                    self.logSlowLoadIfNeeded(startedAt: startedAt, image: image)
                    self.setNeedsLayout()
                }
            } catch {
                await MainActor.run {
                    self.logSlowFailureIfNeeded(startedAt: startedAt, error: error)
                    self.renderState = .failure
                    self.setNeedsLayout()
                }
            }
        }
    }

    @objc private func retryTapped() {
        cancelLoad()
        imageNode.image = nil
        didAttemptLoad = false
        renderState = .loading
        setNeedsLayout()
        loadIfNeeded()
    }

    private func logSlowLoadIfNeeded(startedAt: Date, image: UIImage) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard elapsedMs >= 250 else { return }
        ReaderLogger.shared.log(
            "Webtoon page load slow page=\(pageIndex + 1) source=\(sourceKind) elapsedMs=\(elapsedMs) pixels=\(Int(image.size.width))x\(Int(image.size.height))",
            type: "ReaderPerf"
        )
    }

    private func logSlowFailureIfNeeded(startedAt: Date, error: Error) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        guard elapsedMs >= 250 else { return }
        ReaderLogger.shared.log(
            "Webtoon page load failed page=\(pageIndex + 1) source=\(sourceKind) elapsedMs=\(elapsedMs) error=\(error.localizedDescription)",
            type: "ReaderPerf"
        )
    }

    private var sourceKind: String {
        if page.textContent != nil { return "text" }
        if page.imageData != nil { return "data" }
        if page.readerExtensionResource != nil { return "readerExtension" }
        if let urlString = page.urlString, URL(string: urlString)?.isFileURL == true { return "file" }
        if page.urlString != nil { return "network" }
        return "unknown"
    }

    private static func statusText(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .callout),
                .foregroundColor: UIColor.white.withAlphaComponent(0.7)
            ]
        )
    }

    private static func buttonText(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .callout),
                .foregroundColor: UIColor.white
            ]
        )
    }
}

private protocol WebtoonHeightQueryable {
    func webtoonHeight(for width: CGFloat) -> CGFloat
}

extension WebtoonTexturePageNode: WebtoonHeightQueryable {
    func webtoonHeight(for width: CGFloat) -> CGFloat {
        if let text = page.textContent {
            let constraint = CGSize(width: max(width - 48, 1), height: CGFloat.greatestFiniteMagnitude)
            let rect = (text as NSString).boundingRect(
                with: constraint,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
                context: nil
            )
            return max(320, ceil(rect.height) + 64)
        }

        let ratio = max(imageRatio ?? estimatedRatio, 0.2)
        return max(1, width * ratio)
    }
}

final class WebtoonCollectionView: UICollectionView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

final class WebtoonOffsetPreservingLayout: UICollectionViewLayout {
    var fallbackHeightProvider: ((IndexPath, CGFloat) -> CGFloat)?
    var zoomScale: CGFloat = 1 {
        didSet {
            zoomScale = min(max(zoomScale, 1), 5)
        }
    }

    private var cachedAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var contentSize: CGSize = .zero
    private var lastPreparedWidth: CGFloat = 0
    private var lastPreparedScale: CGFloat = 1

    override func prepare() {
        guard let collectionView else { return }
        let width = max(collectionView.bounds.width, 1)
        guard cachedAttributes.isEmpty
                || abs(width - lastPreparedWidth) >= 0.5
                || abs(zoomScale - lastPreparedScale) >= 0.01 else { return }

        cachedAttributes.removeAll()
        lastPreparedWidth = width
        lastPreparedScale = zoomScale
        var y: CGFloat = 0
        for section in 0..<collectionView.numberOfSections {
            for item in 0..<collectionView.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: item, section: section)
                let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
                let height = max(heightForItem(at: indexPath, width: width), 1)
                attributes.frame = CGRect(
                    x: 0,
                    y: y * zoomScale,
                    width: width * zoomScale,
                    height: height * zoomScale
                )
                cachedAttributes[indexPath] = attributes
                y += height
            }
        }
        contentSize = CGSize(width: width * zoomScale, height: y * zoomScale)
    }

    override var collectionViewContentSize: CGSize {
        contentSize
    }

    override func invalidateLayout() {
        cachedAttributes.removeAll()
        contentSize = .zero
        lastPreparedWidth = 0
        super.invalidateLayout()
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.values
            .filter { $0.frame.intersects(rect) }
            .sorted {
                if $0.indexPath.section == $1.indexPath.section {
                    return $0.indexPath.item < $1.indexPath.item
                }
                return $0.indexPath.section < $1.indexPath.section
            }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return true }
        return abs(collectionView.bounds.width - newBounds.width) >= 0.5
    }

    func frameForItem(at index: Int) -> CGRect? {
        if cachedAttributes.isEmpty {
            prepare()
        }
        return cachedAttributes[IndexPath(item: index, section: 0)]?.frame
    }

    func heightForItem(at indexPath: IndexPath, width: CGFloat) -> CGFloat {
        if let collectionView = collectionView as? ASCollectionView,
           let collectionNode = collectionView.collectionNode,
           let node = collectionNode.nodeForItem(at: indexPath) as? WebtoonHeightQueryable {
            return max(node.webtoonHeight(for: width), 1)
        }
        return max(fallbackHeightProvider?(indexPath, width) ?? width * WebtoonView.Coordinator.defaultImageAspectRatio, 1)
    }

    func indexForY(_ y: CGFloat) -> Int? {
        if cachedAttributes.isEmpty {
            prepare()
        }
        guard !cachedAttributes.isEmpty else { return nil }

        var lower = 0
        var upper = (collectionView?.numberOfItems(inSection: 0) ?? cachedAttributes.count) - 1
        while lower <= upper {
            let middle = (lower + upper) / 2
            guard let frame = frameForItem(at: middle) else {
                break
            }
            if y < frame.minY {
                upper = middle - 1
            } else if y > frame.maxY {
                lower = middle + 1
            } else {
                return middle
            }
        }
        return min(max(lower, 0), cachedAttributes.count - 1)
    }
}

final class WebtoonImageCell: UICollectionViewCell {
    static let reuseIdentifier = "WebtoonImageCell"

    private let pageView = WebtoonPageView()
    private var currentPageId: PageData.ID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let canvasColor = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        contentView.backgroundColor = canvasColor
        backgroundColor = canvasColor
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            pageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentPageId = nil
        pageView.cancelLoad()
        pageView.prepareForReuse()
    }

    func configure(
        page: PageData,
        index: Int,
        targetSize: CGSize,
        scale: CGFloat,
        onImageSize: @escaping (PageData, CGSize, Int) -> Void
    ) {
        currentPageId = page.id
        pageView.configure(page: page, index: index)
        pageView.onImageSize = { [weak self] page, size, index in
            guard self?.currentPageId == page.id else { return }
            onImageSize(page, size, index)
        }
        pageView.onRetry = { [weak self] _ in
            guard self?.currentPageId == page.id else { return }
            self?.pageView.prepareForRetry()
            self?.pageView.loadIfNeeded(targetSize: targetSize, scale: scale)
        }
        pageView.loadIfNeeded(targetSize: targetSize, scale: scale)
    }

    func cancelLoad() {
        pageView.cancelLoad()
    }

    func releaseDisplayedImage() {
        pageView.releaseDisplayedImage()
    }
}

final class WebtoonPageView: UIView, UIGestureRecognizerDelegate {
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private lazy var pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    private var page: PageData?
    private var pageIndex = 0
    private var currentTaskId: UUID?
    private var imageLoadTask: Task<Void, Never>?
    private var imageTask: ImageTask?
    private var didAttemptLoad = false
    private var didLoadSuccessfully = false
    private var zoomScale: CGFloat = 1
    private var zoomTranslation: CGPoint = .zero

    var onImageSize: ((PageData, CGSize, Int) -> Void)?
    var onRetry: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(page: PageData, index: Int) {
        self.page = page
        self.pageIndex = index
        didAttemptLoad = false
        didLoadSuccessfully = false
        currentTaskId = nil
        imageLoadTask?.cancel()
        imageTask?.cancel()
        imageLoadTask = nil
        imageTask = nil
        imageView.image = nil
        textLabel.text = nil
        resetZoom(animated: false)
        showPlaceholder()
    }

    func prepareForReuse() {
        imageLoadTask?.cancel()
        imageTask?.cancel()
        imageLoadTask = nil
        imageTask = nil
        imageView.image = nil
        textLabel.text = nil
        currentTaskId = nil
        didAttemptLoad = false
        didLoadSuccessfully = false
        onImageSize = nil
        onRetry = nil
        resetZoom(animated: false)
        showPlaceholder()
    }

    func prepareForRetry() {
        didAttemptLoad = false
        didLoadSuccessfully = false
        currentTaskId = nil
        imageLoadTask?.cancel()
        imageTask?.cancel()
        imageLoadTask = nil
        imageTask = nil
        imageView.image = nil
    }

    func cancelLoad() {
        imageLoadTask?.cancel()
        imageTask?.cancel()
        imageLoadTask = nil
        imageTask = nil
        currentTaskId = nil
    }

    func releaseDisplayedImage() {
        guard zoomScale <= 1.01 else { return }
        imageLoadTask?.cancel()
        imageTask?.cancel()
        imageLoadTask = nil
        imageTask = nil
        imageView.image = nil
        currentTaskId = nil
        didLoadSuccessfully = false
        didAttemptLoad = false
        showPlaceholder()
    }

    func loadIfNeeded(targetSize: CGSize, scale: CGFloat) {
        guard !didLoadSuccessfully else { return }
        if didAttemptLoad, retryButton.isHidden { return }
        didAttemptLoad = true
        load(targetSize: targetSize, scale: scale)
    }

    private func setup() {
        let canvasColor = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        backgroundColor = canvasColor
        clipsToBounds = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = canvasColor
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        pinchGesture.delegate = self
        panGesture.delegate = self
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        addGestureRecognizer(pinchGesture)
        addGestureRecognizer(panGesture)

        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.numberOfLines = 0
        textLabel.font = .preferredFont(forTextStyle: .body)
        textLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        textLabel.backgroundColor = canvasColor
        addSubview(textLabel)

        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = .white
        addSubview(activityIndicator)

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        var retryConfiguration = UIButton.Configuration.plain()
        retryConfiguration.title = "Retry"
        retryConfiguration.baseForegroundColor = .white
        retryConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        retryButton.configuration = retryConfiguration
        retryButton.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        retryButton.layer.cornerRadius = 12
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        addSubview(retryButton)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),

            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            textLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        showPlaceholder()
    }

    private func load(targetSize: CGSize, scale: CGFloat) {
        guard let page else {
            showFailure()
            return
        }

        if let text = page.textContent {
            textLabel.text = text
            didLoadSuccessfully = true
            showText()
            return
        }

        guard page.isImageLike else {
            showFailure()
            return
        }

        let taskId = UUID()
        currentTaskId = taskId
        showLoading()
        imageLoadTask?.cancel()
        imageTask?.cancel()

        imageLoadTask = Task { [weak self] in
            do {
                let image = try await ReaderWebtoonImagePipeline.loadImage(
                    for: page,
                    targetSize: targetSize,
                    scale: scale,
                    taskSink: { [weak self] task in
                        Task { @MainActor in
                            self?.imageTask = task
                        }
                    }
                )
                await MainActor.run {
                    guard let self,
                          self.currentTaskId == taskId,
                          let currentPage = self.page,
                          currentPage.id == page.id else { return }
                    self.imageView.image = image
                    self.didLoadSuccessfully = true
                    self.showImage()
                    self.onImageSize?(page, image.size, self.pageIndex)
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.currentTaskId == taskId,
                          let currentPage = self.page,
                          currentPage.id == page.id else { return }
                    self.showFailure()
                }
            }
        }
    }

    private func showLoading() {
        imageView.isHidden = true
        textLabel.isHidden = true
        retryButton.isHidden = true
        activityIndicator.isHidden = false
        activityIndicator.startAnimating()
    }

    private func showImage() {
        imageView.isHidden = false
        textLabel.isHidden = true
        retryButton.isHidden = true
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
    }

    private func showText() {
        imageView.isHidden = true
        textLabel.isHidden = false
        retryButton.isHidden = true
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
    }

    private func showFailure() {
        imageView.isHidden = true
        textLabel.isHidden = true
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
        retryButton.isHidden = false
    }

    private func showPlaceholder() {
        imageView.isHidden = true
        textLabel.isHidden = true
        retryButton.isHidden = true
        activityIndicator.stopAnimating()
        activityIndicator.isHidden = true
    }

    @objc private func retryTapped() {
        prepareForRetry()
        onRetry?(pageIndex)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard imageView.image != nil else { return }

        switch gesture.state {
        case .began, .changed:
            zoomScale = min(max(zoomScale * gesture.scale, 1), 4)
            gesture.scale = 1
            if zoomScale <= 1.01 {
                resetZoom(animated: false)
            } else {
                constrainZoomTranslation()
                applyZoomTransform(animated: false)
            }
        case .ended, .cancelled, .failed:
            if zoomScale <= 1.05 {
                resetZoom(animated: true)
            } else {
                constrainZoomTranslation()
                applyZoomTransform(animated: true)
            }
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard imageView.image != nil, zoomScale > 1 else { return }
        let delta = gesture.translation(in: self)
        zoomTranslation.x += delta.x
        zoomTranslation.y += delta.y
        gesture.setTranslation(.zero, in: self)
        constrainZoomTranslation()
        applyZoomTransform(animated: false)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pinchGesture || gestureRecognizer === panGesture
    }

    private func resetZoom(animated: Bool) {
        zoomScale = 1
        zoomTranslation = .zero
        applyZoomTransform(animated: animated)
    }

    private func constrainZoomTranslation() {
        guard zoomScale > 1 else {
            zoomTranslation = .zero
            return
        }
        let maxX = bounds.width * (zoomScale - 1) * 0.5
        let maxY = bounds.height * (zoomScale - 1) * 0.5
        zoomTranslation.x = min(max(zoomTranslation.x, -maxX), maxX)
        zoomTranslation.y = min(max(zoomTranslation.y, -maxY), maxY)
    }

    private func applyZoomTransform(animated: Bool) {
        let changes = {
            self.imageView.transform = CGAffineTransform(
                translationX: self.zoomTranslation.x,
                y: self.zoomTranslation.y
            ).scaledBy(x: self.zoomScale, y: self.zoomScale)
        }

        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }
}

enum ReaderWebtoonImagePipeline {
    private static let decodedImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "Eclipse.Kanzen.Reader.DecodedImages"
        cache.countLimit = 160
        cache.totalCostLimit = 180 * 1024 * 1024
        return cache
    }()

    static func loadImage(
        for page: PageData,
        targetSize: CGSize,
        scale: CGFloat,
        taskSink: ((ImageTask) -> Void)? = nil
    ) async throws -> UIImage {
        let cacheKey = decodedCacheKey(for: page, targetSize: targetSize, scale: scale)
        if let cached = decodedImageCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let rawImage = try await loadImageUncached(
            for: page,
            targetSize: targetSize,
            scale: scale,
            taskSink: taskSink
        )
        let image = await postProcess(rawImage, targetSize: targetSize, scale: scale)
        decodedImageCache.setObject(image, forKey: cacheKey as NSString, cost: cacheCost(for: image))
        return image
    }

    private static func loadImageUncached(
        for page: PageData,
        targetSize: CGSize,
        scale: CGFloat,
        taskSink: ((ImageTask) -> Void)? = nil
    ) async throws -> UIImage {
        if let data = page.imageData {
            return try await decodeImageData(data, targetWidth: targetSize.width, scale: scale)
        }

        if let resource = page.readerExtensionResource {
            let response = try await ReaderExtensionManager.shared.fetchPage(resource)
            try Task.checkCancellation()
            _ = try await Task.detached(priority: .userInitiated) {
                try ReaderExtensionImageSafety.validate(response.body)
            }.value
            return try await decodeImageData(response.body, targetWidth: targetSize.width, scale: scale)
        }

        guard page.urlString != nil else {
            throw ReaderWebtoonImageError.invalidPage
        }
        _ = taskSink
        let request = try ReaderPageImageOptions.request(
            for: page,
            targetSize: targetSize,
            scaleFactor: scale
        )
        let data = try await ReaderPinnedImageLoader.shared.data(for: request)
        try Task.checkCancellation()
        return try await decodeImageData(data, targetWidth: targetSize.width, scale: scale)
    }

    private static func decodedCacheKey(for page: PageData, targetSize: CGSize, scale: CGFloat) -> String {
        "\(page.cacheKey)-w\(Int(max(targetSize.width, 1) * scale))-\(KanzenReaderImageProcessingSettings.cacheSignature)"
    }

    private static var shouldDownsample: Bool {
        KanzenReaderImageProcessingSettings.shouldDownsample
    }

    private static func cacheCost(for image: UIImage) -> Int {
        let pixels = max(image.size.width * image.scale, 1) * max(image.size.height * image.scale, 1)
        return min(Int(pixels * 4), 48 * 1024 * 1024)
    }

    private static func decodeImageData(_ data: Data, targetWidth: CGFloat, scale: CGFloat) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
                throw ReaderWebtoonImageError.decodeFailed
            }
            return try decodeImageSource(source, targetWidth: shouldDownsample ? targetWidth : 0, scale: scale)
        }.value
    }

    private static func decodeImageSource(_ source: CGImageSource, targetWidth: CGFloat, scale: CGFloat) throws -> UIImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = CGFloat((properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0)
        let pixelHeight = CGFloat((properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0)

        let wantsDownsample = targetWidth > 0 && targetWidth.isFinite
        let targetPixelWidth = max(1, targetWidth * scale)
        let maxPixelSize: CGFloat
        if wantsDownsample, pixelWidth > 0, pixelHeight > 0, pixelWidth > targetPixelWidth {
            maxPixelSize = max(targetPixelWidth, pixelHeight * (targetPixelWidth / pixelWidth))
        } else {
            maxPixelSize = max(pixelWidth, pixelHeight, 1)
        }

        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize))
        ] as [CFString: Any] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ReaderWebtoonImageError.decodeFailed
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    private static func postProcess(_ image: UIImage, targetSize: CGSize, scale: CGFloat) async -> UIImage {
        let settings = KanzenReaderImageProcessingSettings.current
        var output = image

        if settings.cropBorders {
            output = KanzenReaderImageProcessor.cropBorders(output) ?? output
        }

        if settings.shouldDownsample {
            output = ReaderWebtoonDownsampleProcessor(
                width: max(targetSize.width, 1),
                scaleFactor: scale
            ).process(output) ?? output
        } else if settings.upscaleImages {
            output = await KanzenReaderUpscaler.upscale(output, maxHeight: settings.upscaleMaxHeight) ?? output
        }

        return output
    }
}

private enum ReaderWebtoonImageError: Error {
    case invalidPage
    case decodeFailed
    case pageTooLarge
}

private struct KanzenReaderImageProcessingSettings {
    let shouldDownsample: Bool
    let cropBorders: Bool
    let upscaleImages: Bool
    let upscaleMaxHeight: Int
    let modelName: String

    static var current: KanzenReaderImageProcessingSettings {
        let defaults = ProfileSettingsStore.active
        let shouldDownsample = defaults.object(forKey: "Reader.downsampleImages") == nil ? true : defaults.bool(forKey: "Reader.downsampleImages")
        let maxHeight = defaults.object(forKey: "Reader.upscaleMaxHeight") as? Int ?? 2000
        return KanzenReaderImageProcessingSettings(
            shouldDownsample: shouldDownsample,
            cropBorders: defaults.bool(forKey: "Reader.cropBorders"),
            upscaleImages: defaults.bool(forKey: "Reader.upscaleImages") && !shouldDownsample,
            upscaleMaxHeight: min(max(maxHeight, 800), 6000),
            modelName: KanzenReaderUpscaleModelStore.storedModelName
        )
    }

    static var shouldDownsample: Bool {
        current.shouldDownsample
    }

    static var cacheSignature: String {
        let settings = current
        return "ds\(settings.shouldDownsample ? 1 : 0)-crop\(settings.cropBorders ? 1 : 0)-up\(settings.upscaleImages ? 1 : 0)-h\(settings.upscaleMaxHeight)-m\(settings.modelName.hashValue)"
    }
}

private enum KanzenReaderImageProcessor {
    static func cropBorders(_ image: UIImage) -> UIImage? {
        guard let cgImage = normalizedCGImage(for: image) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 8, height > 8 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func pixel(atX x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]), Int(pixels[offset + 3]))
        }

        let borderStepX = max(1, width / 40)
        let borderStepY = max(1, height / 40)
        var samples: [(r: Int, g: Int, b: Int, a: Int)] = []
        for x in stride(from: 0, to: width, by: borderStepX) {
            samples.append(pixel(atX: x, y: 0))
            samples.append(pixel(atX: x, y: height - 1))
        }
        for y in stride(from: 0, to: height, by: borderStepY) {
            samples.append(pixel(atX: 0, y: y))
            samples.append(pixel(atX: width - 1, y: y))
        }
        guard !samples.isEmpty else { return nil }
        let borderColor = samples.reduce((r: 0, g: 0, b: 0, a: 0)) { partial, sample in
            (partial.r + sample.r, partial.g + sample.g, partial.b + sample.b, partial.a + sample.a)
        }
        let count = max(samples.count, 1)
        let average = (
            r: borderColor.r / count,
            g: borderColor.g / count,
            b: borderColor.b / count,
            a: borderColor.a / count
        )

        func isBorderPixel(_ sample: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            if sample.a <= 10 { return true }
            let distance = abs(sample.r - average.r) + abs(sample.g - average.g) + abs(sample.b - average.b)
            let nearWhite = sample.r >= 245 && sample.g >= 245 && sample.b >= 245
            let nearBlack = sample.r <= 10 && sample.g <= 10 && sample.b <= 10
            return distance <= 42 || nearWhite || nearBlack
        }

        func rowLooksLikeBorder(_ y: Int) -> Bool {
            let step = max(1, width / 180)
            var matches = 0
            var total = 0
            for x in stride(from: 0, to: width, by: step) {
                total += 1
                if isBorderPixel(pixel(atX: x, y: y)) {
                    matches += 1
                }
            }
            return total > 0 && Double(matches) / Double(total) >= 0.94
        }

        func columnLooksLikeBorder(_ x: Int, from top: Int, through bottom: Int) -> Bool {
            let step = max(1, height / 180)
            var matches = 0
            var total = 0
            for y in stride(from: top, through: bottom, by: step) {
                total += 1
                if isBorderPixel(pixel(atX: x, y: y)) {
                    matches += 1
                }
            }
            return total > 0 && Double(matches) / Double(total) >= 0.94
        }

        let maxVerticalCrop = Int(Double(height) * 0.35)
        let maxHorizontalCrop = Int(Double(width) * 0.35)
        var top = 0
        while top < maxVerticalCrop, rowLooksLikeBorder(top) {
            top += 1
        }

        var bottom = height - 1
        while height - 1 - bottom < maxVerticalCrop, bottom > top, rowLooksLikeBorder(bottom) {
            bottom -= 1
        }

        var left = 0
        while left < maxHorizontalCrop, columnLooksLikeBorder(left, from: top, through: bottom) {
            left += 1
        }

        var right = width - 1
        while width - 1 - right < maxHorizontalCrop, right > left, columnLooksLikeBorder(right, from: top, through: bottom) {
            right -= 1
        }

        let cropWidth = right - left + 1
        let cropHeight = bottom - top + 1
        guard cropWidth > 0, cropHeight > 0 else { return nil }
        let croppedArea = Double(cropWidth * cropHeight)
        let originalArea = Double(width * height)
        guard croppedArea / originalArea >= 0.45 else { return nil }
        guard left > 1 || top > 1 || width - 1 - right > 1 || height - 1 - bottom > 1 else { return nil }

        guard let cropped = cgImage.cropping(to: CGRect(x: left, y: top, width: cropWidth, height: cropHeight)) else {
            return nil
        }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }

    private static func normalizedCGImage(for image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage, image.imageOrientation == .up {
            return cgImage
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}

private enum KanzenReaderUpscaler {
    static func upscale(_ sourceImage: UIImage, maxHeight: Int) async -> UIImage? {
        guard ProfileSettingsStore.active.bool(forKey: "Reader.upscaleImages"),
              FileManager.default.fileExists(atPath: KanzenReaderUpscaleModelStore.storedModelURL.path),
              let cgImage = sourceImage.cgImage else {
            return nil
        }
        let pixelHeight = max(cgImage.height, 1)
        guard pixelHeight < maxHeight else { return sourceImage }

#if canImport(CoreML) && canImport(Vision)
        if #available(iOS 15.0, *) {
            return await Task.detached(priority: .userInitiated) {
                do {
                    let compiledURL = try MLModel.compileModel(at: KanzenReaderUpscaleModelStore.storedModelURL)
                    let mlModel = try MLModel(contentsOf: compiledURL)
                    let visionModel = try VNCoreMLModel(for: mlModel)
                    let request = VNCoreMLRequest(model: visionModel)
                    request.imageCropAndScaleOption = .scaleFit
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])

                    if let observation = request.results?.first as? VNPixelBufferObservation {
                        return image(from: observation.pixelBuffer, scale: sourceImage.scale)
                    }

                    if let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
                       let pixelBuffer = observation.featureValue.imageBufferValue {
                        return image(from: pixelBuffer, scale: sourceImage.scale)
                    }
                } catch {
                    ReaderLogger.shared.log("Reader upscaling skipped: \(error.localizedDescription)", type: "ReaderSettings")
                }
                return nil
            }.value
        }
#endif
        return nil
    }

#if canImport(CoreML) && canImport(Vision)
    private static func image(from pixelBuffer: CVPixelBuffer, scale: CGFloat) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
#endif
}

private struct ReaderWebtoonDownsampleProcessor: ImageProcessing {
    let width: CGFloat
    let scaleFactor: CGFloat

    var identifier: String {
        "app.eclipse.soupy.reader.webtoon.downsample?w=\(Int(width * scaleFactor))"
    }

    func process(_ image: PlatformImage) -> PlatformImage? {
        guard image.size.width > width, width > 0 else { return image }

        let finalWidth = width
        let finalHeight = image.size.height * (finalWidth / image.size.width)
        let finalSize = CGSize(width: finalWidth, height: finalHeight)

        var data = image.pngData()
        if data == nil {
            data = image.jpegData(compressionQuality: 1)
        }
        guard let data else { return image }

        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else {
            return image
        }

        let maxDimension = round(max(finalSize.width, finalSize.height) * scaleFactor)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as [CFString: Any] as CFDictionary

        guard let output = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return image
        }
        return PlatformImage(cgImage: output, scale: scaleFactor, orientation: image.imageOrientation)
    }
}

protocol KanzenReaderHeightQueryable {
    func kanzenReaderHeight(for width: CGFloat) -> CGFloat
}

final class KanzenWebtoonReaderViewController: UIViewController, KanzenReaderChildControlling {
    weak var readerDelegate: KanzenReaderChildDelegate?

    private let layout = KanzenVerticalContentOffsetPreservingLayout()
    private lazy var zoomView = KanzenZoomableTextureView(layout: layout)
    private var pages: [KanzenReaderPage] = []
    private var recentRatios: [CGFloat] = []
    private var pageRatios: [String: CGFloat] = [:]
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var pendingStartPage: Int?
    private var lastReportedPage = -1
    private var didInitialScroll = false
    private var requestedNextChapterFromOverscroll = false

    override func loadView() {
        view = zoomView
    }

    deinit {
        cancelPrefetchTasks()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyCanvasColor()
        layout.itemCountProvider = { [weak self] in self?.pages.count ?? 0 }
        layout.fallbackHeightProvider = { [weak self] indexPath, width in
            self?.estimatedHeight(for: indexPath.item, width: width) ?? width * KanzenWebtoonPageNode.defaultRatio
        }
        layout.pillarboxInsetProvider = { [weak self] width in
            guard ProfileSettingsStore.active.bool(forKey: "Reader.pillarbox") else { return 0 }
            let orientation = ProfileSettingsStore.active.string(forKey: "Reader.pillarboxOrientation") ?? "both"
            if orientation != "both" {
                let bounds = self?.view.bounds ?? UIScreen.main.bounds
                let isLandscape = bounds.width > bounds.height
                if orientation == "portrait", isLandscape { return 0 }
                if orientation == "landscape", !isLandscape { return 0 }
            }
            let storedAmount = ProfileSettingsStore.active.object(forKey: "Reader.pillarboxAmount") as? Double ?? 15
            let amount = storedAmount.isFinite ? min(max(storedAmount, 0), 90) : 15
            let fraction = CGFloat(amount) / 100
            return floor(width * fraction * 0.5)
        }
        zoomView.collectionNode.dataSource = self
        zoomView.collectionNode.delegate = self
        zoomView.collectionNode.backgroundColor = view.backgroundColor
        zoomView.collectionNode.view.backgroundColor = view.backgroundColor
        zoomView.collectionNode.view.isScrollEnabled = false
        zoomView.collectionNode.automaticallyManagesSubnodes = true
        zoomView.collectionNode.shouldAnimateSizeChanges = false
        zoomView.collectionNode.insetsLayoutMarginsFromSafeArea = false
        zoomView.collectionNode.setTuningParameters(zoomView.collectionNode.tuningParameters(for: .display), for: .minimum, rangeType: .display)
        zoomView.collectionNode.setTuningParameters(zoomView.collectionNode.tuningParameters(for: .preload), for: .minimum, rangeType: .preload)
        zoomView.collectionNode.setTuningParameters(zoomView.collectionNode.tuningParameters(for: .display), for: .lowMemory, rangeType: .display)
        zoomView.collectionNode.setTuningParameters(zoomView.collectionNode.tuningParameters(for: .preload), for: .lowMemory, rangeType: .preload)
        zoomView.onScroll = { [weak self] in self?.scrollViewDidMirrorScroll() }
        zoomView.onLayout = { [weak self] in self?.layoutDidUpdate() }
        zoomView.onEndOverscroll = { [weak self] in self?.requestNextChapterFromOverscroll() }
        zoomView.doubleTapEnabled = !ProfileSettingsStore.active.bool(forKey: "Reader.disableDoubleTap")

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.require(toFail: zoomView.doubleTapGesture)
        zoomView.addGestureRecognizer(tap)
    }

    func setPages(_ pages: [KanzenReaderPage], startPage: Int) {
        self.pages = pages
        recentRatios.removeAll()
        pageRatios.removeAll()
        cancelPrefetchTasks()
        pendingStartPage = min(max(startPage, 0), max(pages.count - 1, 0))
        lastReportedPage = -1
        didInitialScroll = false
        requestedNextChapterFromOverscroll = false
        layout.zoomScale = 1
        layout.invalidateLayout()
        zoomView.resetZoom()
        zoomView.collectionNode.reloadData()
        zoomView.setNeedsLayout()
        prefetchPages(around: pendingStartPage ?? 0)
        DispatchQueue.main.async { [weak self] in
            self?.scrollToPendingStartPage()
        }
    }

    func applyReaderSettings(reloadCurrentPages: Bool) {
        applyCanvasColor()
        zoomView.doubleTapEnabled = !ProfileSettingsStore.active.bool(forKey: "Reader.disableDoubleTap")
        if reloadCurrentPages {
            setPages(pages, startPage: max(lastReportedPage, 0))
            return
        }
        layout.invalidateLayout()
        zoomView.collectionNode.view.layoutIfNeeded()
        zoomView.adjustContentSize()
        prefetchPages(around: max(lastReportedPage, 0))
    }

    private func requestNextChapterFromOverscroll() {
        guard !requestedNextChapterFromOverscroll else { return }
        guard lastReportedPage >= pages.count - 1 else { return }
        if ProfileSettingsStore.active.object(forKey: "Reader.verticalInfiniteScroll") != nil,
           !ProfileSettingsStore.active.bool(forKey: "Reader.verticalInfiniteScroll") {
            return
        }
        if readerDelegate?.readerChildDidRequestNextChapter() == true {
            requestedNextChapterFromOverscroll = true
        }
    }

    func moveToPage(_ page: Int, animated: Bool) {
        guard !pages.isEmpty else { return }
        let target = min(max(page, 0), pages.count - 1)
        let indexPath = IndexPath(item: target, section: 0)
        zoomView.collectionNode.view.layoutIfNeeded()
        let frame = layout.layoutAttributesForItem(at: indexPath)?.frame
        let offsetY = frame?.origin.y ?? estimatedOffset(for: target)
        zoomView.setContentOffset(CGPoint(x: 0, y: max(offsetY, 0)), animated: animated)
        prefetchPages(around: target)
        updateCurrentPage(force: true)
    }

    func moveLeft() {
        moveToPage(max(lastReportedPage - 1, 0), animated: kanzenReaderAnimatesPageTransitions())
    }

    func moveRight() {
        moveToPage(min(max(lastReportedPage + 1, 0), max(pages.count - 1, 0)), animated: kanzenReaderAnimatesPageTransitions())
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: view)
        if let action = KanzenTapZone.action(at: point, in: view.bounds, kind: .webtoon) {
            performTapZoneAction(action)
            return
        }
        readerDelegate?.readerChildDidRequestOverlayToggle()
    }

    private func performTapZoneAction(_ action: KanzenTapZone.RegionType) {
        let resolved: KanzenTapZone.RegionType
        if ProfileSettingsStore.active.bool(forKey: "Reader.invertTapZones") {
            resolved = action == .left ? .right : .left
        } else {
            resolved = action
        }

        switch resolved {
        case .left:
            moveLeft()
        case .right:
            moveRight()
        }
    }

    private func scrollViewDidMirrorScroll() {
        updateCurrentPage(force: false)
        if ProfileSettingsStore.active.bool(forKey: "Reader.hideBarsOnSwipe"), zoomView.scrollView.isDragging {
            readerDelegate?.readerChildDidRequestOverlayToggle()
        }
    }

    private func layoutDidUpdate() {
        zoomView.adjustContentSize()
        scrollToPendingStartPage()
    }

    private func scrollToPendingStartPage() {
        guard !didInitialScroll, let page = pendingStartPage, !pages.isEmpty else { return }
        zoomView.collectionNode.view.layoutIfNeeded()
        moveToPage(page, animated: false)
        pendingStartPage = nil
        didInitialScroll = true
    }

    private func updateCurrentPage(force: Bool) {
        guard !pages.isEmpty else { return }
        let scrollView = zoomView.scrollView
        let midpoint = CGPoint(
            x: scrollView.contentOffset.x + scrollView.bounds.width * 0.5,
            y: scrollView.contentOffset.y + scrollView.bounds.height * 0.5
        )
        let index = zoomView.collectionNode.view.indexPathForItem(at: midpoint)?.item
            ?? layout.indexForY(midpoint.y)
            ?? 0
        let safeIndex = min(max(index, 0), pages.count - 1)
        guard force || safeIndex != lastReportedPage else { return }
        lastReportedPage = safeIndex
        readerDelegate?.readerChildDidChangePage(safeIndex, totalPages: pages.count)
        prefetchPages(around: safeIndex)
        if safeIndex >= pages.count - 1 {
            readerDelegate?.readerChildDidReachEnd()
        }
    }

    private func updateHeight(page: KanzenReaderPage, size: CGSize?, index: Int) {
        guard index < pages.count, pages[index].id == page.id else { return }
        if let size, size.width > 0, size.height > 0 {
            let ratio = size.height / size.width
            if ratio.isFinite {
                pageRatios[page.id] = ratio
                recentRatios.append(ratio)
                if recentRatios.count > 20 {
                    recentRatios.removeFirst(recentRatios.count - 20)
                }
            }
        }

        let oldFrame = layout.frameForItem(at: IndexPath(item: index, section: 0))
        let wasAbove = (oldFrame?.maxY ?? 0) <= zoomView.scrollView.contentOffset.y + 1
        let oldHeight = oldFrame?.height ?? estimatedHeight(for: index, width: max(view.bounds.width, 1))
        layout.invalidateLayout()
        zoomView.collectionNode.view.layoutIfNeeded()
        zoomView.adjustContentSize()

        if wasAbove,
           let newFrame = layout.frameForItem(at: IndexPath(item: index, section: 0)) {
            let delta = newFrame.height - oldHeight
            guard abs(delta) >= 1 else { return }
            let next = CGPoint(
                x: zoomView.scrollView.contentOffset.x,
                y: max(0, zoomView.scrollView.contentOffset.y + delta)
            )
            zoomView.setContentOffset(next, animated: false)
        }
    }

    private func estimatedHeight(for index: Int, width: CGFloat) -> CGFloat {
        guard index >= 0, index < pages.count else {
            return width * KanzenWebtoonPageNode.defaultRatio
        }
        if let text = pages[index].text {
            let constraint = CGSize(width: max(width - 48, 1), height: CGFloat.greatestFiniteMagnitude)
            let rect = (text as NSString).boundingRect(
                with: constraint,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
                context: nil
            )
            return max(320, ceil(rect.height) + 64)
        }
        if let ratio = pageRatios[pages[index].id] {
            return max(1, width * ratio)
        }
        return max(320, width * estimatedRatio())
    }

    private func estimatedOffset(for page: Int) -> CGFloat {
        let width = max(view.bounds.width, 1)
        return (0..<page).reduce(CGFloat(0)) { $0 + estimatedHeight(for: $1, width: width) }
    }

    private func estimatedRatio() -> CGFloat {
        guard !recentRatios.isEmpty else { return KanzenWebtoonPageNode.defaultRatio }
        let sorted = recentRatios.sorted()
        return min(max(sorted[sorted.count / 2], 1.1), 6)
    }

    private func prefetchPages(around center: Int) {
        guard !pages.isEmpty else { return }
        let radius = max(0, ProfileSettingsStore.active.object(forKey: "Reader.pagesToPreload") as? Int ?? 3)
        guard radius > 0 else {
            cancelPrefetchTasks()
            return
        }

        let lower = max(center - radius, 0)
        let upper = min(center + radius, pages.count - 1)
        let targetIDs = Set(pages[lower...upper].map(\.id))

        let staleIDs = prefetchTasks.keys.filter { !targetIDs.contains($0) }
        for id in staleIDs {
            prefetchTasks[id]?.cancel()
            prefetchTasks[id] = nil
        }

        let targetSize = targetImageSize()
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        for index in lower...upper {
            let page = pages[index]
            guard page.isImageLike, prefetchTasks[page.id] == nil else { continue }
            prefetchTasks[page.id] = Task(priority: .utility) { [weak self, page, targetSize, scale] in
                _ = try? await ReaderWebtoonImagePipeline.loadImage(
                    for: page.pageData,
                    targetSize: targetSize,
                    scale: scale
                )
                await MainActor.run {
                    self?.prefetchTasks[page.id] = nil
                }
            }
        }
    }

    private func cancelPrefetchTasks() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
    }

    private func targetImageSize() -> CGSize {
        let width = max(view.bounds.width * max(layout.zoomScale, 1), UIScreen.main.bounds.width, 1)
        return CGSize(width: width, height: width * 2)
    }

    private func applyCanvasColor() {
        let color = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        view.backgroundColor = color
        zoomView.backgroundColor = color
        zoomView.collectionNode.backgroundColor = color
        zoomView.collectionNode.view.backgroundColor = color
    }
}

extension KanzenWebtoonReaderViewController: ASCollectionDataSource, ASCollectionDelegate {
    func numberOfSections(in collectionNode: ASCollectionNode) -> Int { 1 }

    func collectionNode(_ collectionNode: ASCollectionNode, numberOfItemsInSection section: Int) -> Int {
        pages.count
    }

    func collectionNode(_ collectionNode: ASCollectionNode, nodeBlockForItemAt indexPath: IndexPath) -> ASCellNodeBlock {
        guard indexPath.item < pages.count else { return { ASCellNode() } }
        let page = pages[indexPath.item]
        let targetWidth = max(collectionNode.bounds.width * max(layout.zoomScale, 1), UIScreen.main.bounds.width)
        let targetSize = CGSize(width: targetWidth, height: targetWidth * 2)
        let scale = collectionNode.view.window?.screen.scale ?? UIScreen.main.scale
        return { [weak self] in
            let node = KanzenWebtoonPageNode(
                page: page,
                targetSize: targetSize,
                scale: scale,
                estimatedRatio: self?.estimatedRatio() ?? KanzenWebtoonPageNode.defaultRatio
            )
            node.onHeightChanged = { [weak self] page, size, index in
                self?.updateHeight(page: page, size: size, index: index)
            }
            return node
        }
    }
}

final class KanzenZoomableTextureView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let collectionNode: ASCollectionNode
    let scrollView = UIScrollView()
    let dummyZoomView = UIView()
    let layout: KanzenVerticalContentOffsetPreservingLayout
    var onScroll: (() -> Void)?
    var onLayout: (() -> Void)?
    var onEndOverscroll: (() -> Void)?

    private var pinchStartScale: CGFloat = 1

    var doubleTapEnabled: Bool {
        get { doubleTapGesture.isEnabled }
        set { doubleTapGesture.isEnabled = newValue }
    }

    lazy var doubleTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        gesture.numberOfTapsRequired = 2
        return gesture
    }()

    private lazy var pinchGesture: UIPinchGestureRecognizer = {
        let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        gesture.delegate = self
        return gesture
    }()

    init(layout: KanzenVerticalContentOffsetPreservingLayout) {
        self.layout = layout
        self.collectionNode = ASCollectionNode(collectionViewLayout: layout)
        super.init(frame: .zero)
        let canvasColor = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        backgroundColor = canvasColor

        collectionNode.view.backgroundColor = canvasColor
        collectionNode.view.contentInsetAdjustmentBehavior = .never
        collectionNode.view.showsVerticalScrollIndicator = false
        collectionNode.view.showsHorizontalScrollIndicator = false
        collectionNode.view.bounces = false
        addSubview(collectionNode.view)

        scrollView.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        dummyZoomView.backgroundColor = .clear
        dummyZoomView.addGestureRecognizer(doubleTapGesture)
        scrollView.addGestureRecognizer(pinchGesture)
        dummyZoomView.isUserInteractionEnabled = true
        scrollView.addSubview(dummyZoomView)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionNode.view.frame = bounds
        scrollView.frame = bounds
        adjustContentSize()
        onLayout?()
    }

    func adjustContentSize() {
        collectionNode.view.collectionViewLayout.prepare()
        let contentSize = collectionNode.view.collectionViewLayout.collectionViewContentSize
        scrollView.contentSize = contentSize
        dummyZoomView.frame = CGRect(origin: .zero, size: contentSize)
    }

    func setContentOffset(_ point: CGPoint, animated: Bool) {
        let bounded = boundedOffset(point)
        scrollView.setContentOffset(bounded, animated: animated)
        collectionNode.setContentOffset(bounded, animated: false)
    }

    func resetZoom() {
        setReaderZoomScale(1, anchor: CGPoint(x: bounds.midX, y: bounds.midY), animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        collectionNode.contentOffset = scrollView.contentOffset
        onScroll?()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        detectEndOverscroll(in: scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        detectEndOverscroll(in: scrollView)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pinchGesture || otherGestureRecognizer === pinchGesture
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let targetScale: CGFloat = layout.zoomScale > 1.01 ? 1 : 2
        setReaderZoomScale(targetScale, anchor: gesture.location(in: self), animated: true)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = layout.zoomScale
        case .changed, .ended:
            setReaderZoomScale(pinchStartScale * gesture.scale, anchor: gesture.location(in: self), animated: false)
        default:
            break
        }
    }

    private func setReaderZoomScale(_ scale: CGFloat, anchor: CGPoint, animated: Bool) {
        let oldScale = max(layout.zoomScale, 1)
        let nextScale = min(max(scale, 1), 5)
        guard abs(oldScale - nextScale) >= 0.01 || nextScale == 1 else { return }
        let anchorContent = CGPoint(
            x: (scrollView.contentOffset.x + anchor.x) / oldScale,
            y: (scrollView.contentOffset.y + anchor.y) / oldScale
        )

        let changes = {
            self.layout.zoomScale = nextScale
            self.layout.invalidateLayout()
            self.relayoutVisibleNodesForZoom()
            let targetOffset = CGPoint(
                x: anchorContent.x * nextScale - anchor.x,
                y: anchorContent.y * nextScale - anchor.y
            )
            self.setContentOffset(targetOffset, animated: false)
        }

        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    private func relayoutVisibleNodesForZoom() {
        collectionNode.visibleNodes.forEach { node in
            node.invalidateCalculatedLayout()
            node.setNeedsLayout()
        }
        collectionNode.view.setNeedsLayout()
        collectionNode.view.layoutIfNeeded()
        adjustContentSize()
    }

    private func boundedOffset(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), max(scrollView.contentSize.width - scrollView.bounds.width, 0)),
            y: min(max(point.y, 0), max(scrollView.contentSize.height - scrollView.bounds.height, 0))
        )
    }

    private func detectEndOverscroll(in scrollView: UIScrollView) {
        let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let threshold = max(64, min(scrollView.bounds.height * 0.12, 120))
        guard scrollView.contentOffset.y > maxOffset + threshold else { return }
        onEndOverscroll?()
    }
}

final class KanzenVerticalContentOffsetPreservingLayout: UICollectionViewLayout {
    var itemCountProvider: (() -> Int)?
    var fallbackHeightProvider: ((IndexPath, CGFloat) -> CGFloat)?
    var pillarboxInsetProvider: ((CGFloat) -> CGFloat)?
    var zoomScale: CGFloat = 1 {
        didSet { zoomScale = min(max(zoomScale, 1), 5) }
    }

    private var attributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var contentSize = CGSize.zero

    override var collectionViewContentSize: CGSize { contentSize }

    override func prepare() {
        guard let collectionView else { return }
        attributes.removeAll()

        let fullWidth = max(collectionView.bounds.width, 1)
        let inset = min(max(pillarboxInsetProvider?(fullWidth) ?? 0, 0), fullWidth * 0.45)
        let width = max(fullWidth - inset * 2, 1)
        var y: CGFloat = 0
        if let itemCount = itemCountProvider?(), itemCount > 0 {
            for item in 0..<itemCount {
                let indexPath = IndexPath(item: item, section: 0)
                let height = heightForItem(at: indexPath, width: width)
                let itemAttributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
                itemAttributes.frame = CGRect(x: inset * zoomScale, y: y * zoomScale, width: width * zoomScale, height: height * zoomScale)
                attributes[indexPath] = itemAttributes
                y += height
            }
        } else {
            for section in 0..<collectionView.numberOfSections {
                for item in 0..<collectionView.numberOfItems(inSection: section) {
                    let indexPath = IndexPath(item: item, section: section)
                    let height = heightForItem(at: indexPath, width: width)
                    let itemAttributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
                    itemAttributes.frame = CGRect(x: inset * zoomScale, y: y * zoomScale, width: width * zoomScale, height: height * zoomScale)
                    attributes[indexPath] = itemAttributes
                    y += height
                }
            }
        }
        contentSize = CGSize(width: fullWidth * zoomScale, height: y * zoomScale)
    }

    override func invalidateLayout() {
        attributes.removeAll()
        contentSize = .zero
        super.invalidateLayout()
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.values
            .filter { $0.frame.intersects(rect) }
            .sorted { $0.indexPath.item < $1.indexPath.item }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        if attributes.isEmpty { prepare() }
        return attributes[indexPath]
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        true
    }

    func frameForItem(at indexPath: IndexPath) -> CGRect? {
        if attributes.isEmpty { prepare() }
        return attributes[indexPath]?.frame
    }

    func indexForY(_ y: CGFloat) -> Int? {
        if attributes.isEmpty { prepare() }
        guard !attributes.isEmpty else { return nil }
        let sorted = attributes.values.sorted { $0.indexPath.item < $1.indexPath.item }
        if let match = sorted.first(where: { $0.frame.minY <= y && y <= $0.frame.maxY }) {
            return match.indexPath.item
        }
        return sorted.last(where: { $0.frame.minY <= y })?.indexPath.item ?? 0
    }

    private func heightForItem(at indexPath: IndexPath, width: CGFloat) -> CGFloat {
        return max(fallbackHeightProvider?(indexPath, width) ?? width * KanzenWebtoonPageNode.defaultRatio, 1)
    }
}

final class KanzenWebtoonPageNode: ASCellNode, KanzenReaderHeightQueryable, UIContextMenuInteractionDelegate {
    static let defaultRatio: CGFloat = 1.435

    private enum State {
        case loading
        case image
        case text
        case failed
    }

    let page: KanzenReaderPage
    let targetSize: CGSize
    let scale: CGFloat
    let estimatedRatio: CGFloat
    var onHeightChanged: ((KanzenReaderPage, CGSize?, Int) -> Void)?

    private let imageNode = ASImageNode()
    private let textNode = ASTextNode()
    private let statusNode = ASTextNode()
    private let retryNode = ASButtonNode()
    private var state: State = .loading
    private var ratio: CGFloat?
    private var didStart = false
    private var loadTask: Task<Void, Never>?
    private var imageTask: ImageTask?
    private var analysisTask: Task<Void, Never>?

    init(page: KanzenReaderPage, targetSize: CGSize, scale: CGFloat, estimatedRatio: CGFloat) {
        self.page = page
        self.targetSize = targetSize
        self.scale = scale
        self.estimatedRatio = estimatedRatio
        super.init()
        automaticallyManagesSubnodes = true
        shouldAnimateSizeChanges = false
        let canvasColor = kanzenReaderCanvasColor(for: .dark)
        backgroundColor = canvasColor

        imageNode.backgroundColor = canvasColor
        imageNode.contentMode = .scaleToFill
        imageNode.shouldAnimateSizeChanges = false

        textNode.maximumNumberOfLines = 0
        statusNode.attributedText = Self.labelText("Loading...")
        retryNode.setAttributedTitle(Self.buttonText("Retry"), for: .normal)
        retryNode.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        retryNode.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        retryNode.addTarget(self, action: #selector(retryTapped), forControlEvents: .touchUpInside)
    }

    deinit {
        cancel()
    }

    override func didEnterPreloadState() {
        super.didEnterPreloadState()
        loadIfNeeded()
    }

    override func didEnterDisplayState() {
        super.didEnterDisplayState()
        loadIfNeeded()
        if case .image = state {
            configureLiveText(for: imageNode.image)
        }
    }

    override func didExitDisplayState() {
        super.didExitDisplayState()
        analysisTask?.cancel()
    }

    override func didLoad() {
        super.didLoad()
        imageNode.view.isUserInteractionEnabled = true
        imageNode.view.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let child: ASLayoutElement
        switch state {
        case .image:
            child = imageNode
        case .text:
            child = ASInsetLayoutSpec(insets: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), child: textNode)
        case .failed:
            child = ASCenterLayoutSpec(horizontalPosition: .center, verticalPosition: .center, sizingOption: [], child: retryNode)
        case .loading:
            child = ASCenterLayoutSpec(horizontalPosition: .center, verticalPosition: .center, sizingOption: [], child: statusNode)
        }
        return ASRatioLayoutSpec(ratio: max(ratio ?? estimatedRatio, 0.2), child: child)
    }

    func kanzenReaderHeight(for width: CGFloat) -> CGFloat {
        if let text = page.text {
            let constraint = CGSize(width: max(width - 48, 1), height: CGFloat.greatestFiniteMagnitude)
            let rect = (text as NSString).boundingRect(
                with: constraint,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body)],
                context: nil
            )
            return max(320, ceil(rect.height) + 64)
        }
        return max(1, width * max(ratio ?? estimatedRatio, 0.2))
    }

    private func loadIfNeeded() {
        guard !didStart else { return }
        didStart = true

        if let text = page.text {
            textNode.attributedText = NSAttributedString(
                string: text,
                attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.white]
            )
            state = .text
            onHeightChanged?(page, nil, page.index)
            setNeedsLayout()
            return
        }

        guard page.isImageLike else {
            state = .failed
            setNeedsLayout()
            return
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await ReaderWebtoonImagePipeline.loadImage(
                    for: page.pageData,
                    targetSize: targetSize,
                    scale: scale,
                    taskSink: { [weak self] task in
                        Task { @MainActor in self?.imageTask = task }
                    }
                )
                await MainActor.run {
                    self.imageNode.image = image
                    self.configureLiveText(for: image)
                    self.ratio = image.size.width > 0 ? image.size.height / image.size.width : self.estimatedRatio
                    self.state = .image
                    self.onHeightChanged?(self.page, image.size, self.page.index)
                    self.invalidateCalculatedLayout()
                    self.setNeedsLayout()
                }
            } catch {
                await MainActor.run {
                    self.state = .failed
                    self.setNeedsLayout()
                }
            }
        }
    }

    private func cancel() {
        imageTask?.cancel()
        loadTask?.cancel()
        analysisTask?.cancel()
        imageTask = nil
        loadTask = nil
        analysisTask = nil
    }

    @objc private func retryTapped() {
        cancel()
        imageNode.image = nil
        configureLiveText(for: nil)
        state = .loading
        didStart = false
        setNeedsLayout()
        loadIfNeeded()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !ProfileSettingsStore.active.bool(forKey: "Reader.disableQuickActions"),
              let image = imageNode.image else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(image)
            }
            let save = UIAction(title: "Save Image", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
            let reload = UIAction(title: "Reload Page", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.retryTapped()
            }
            return UIMenu(title: "", children: [share, save, reload])
        }
    }

    private func share(_ image: UIImage) {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = imageNode.view
        controller.popoverPresentationController?.sourceRect = imageNode.view.bounds
        owningViewController?.present(controller, animated: true)
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = imageNode.view
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }

    private func configureLiveText(for image: UIImage?) {
        analysisTask?.cancel()
#if canImport(VisionKit)
        guard #available(iOS 16.0, *),
              ProfileSettingsStore.active.bool(forKey: "Reader.liveText"),
              let image else {
            if #available(iOS 16.0, *) {
                removeImageAnalysisInteraction()
            }
            return
        }

        let interaction = imageAnalysisInteraction()
        interaction.analysis = nil
        analysisTask = Task { [weak self, image] in
            do {
                let analyzer = ImageAnalyzer()
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await analyzer.analyze(image, configuration: configuration)
                await MainActor.run {
                    guard let currentImage = self?.imageNode.image, currentImage === image else { return }
                    interaction.analysis = analysis
                    interaction.preferredInteractionTypes = .automatic
                }
            } catch {
                ReaderLogger.shared.log("Reader Live Text skipped: \(error.localizedDescription)", type: "ReaderSettings")
            }
        }
#else
        _ = image
#endif
    }

#if canImport(VisionKit)
    @available(iOS 16.0, *)
    private func imageAnalysisInteraction() -> ImageAnalysisInteraction {
        if let existing = imageNode.view.interactions.compactMap({ $0 as? ImageAnalysisInteraction }).first {
            return existing
        }
        let interaction = ImageAnalysisInteraction()
        imageNode.view.addInteraction(interaction)
        return interaction
    }

    @available(iOS 16.0, *)
    private func removeImageAnalysisInteraction() {
        imageNode.view.interactions.compactMap { $0 as? ImageAnalysisInteraction }.forEach {
            imageNode.view.removeInteraction($0)
        }
    }
#endif

    private static func labelText(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .callout), .foregroundColor: UIColor.white.withAlphaComponent(0.7)]
        )
    }

    private static func buttonText(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .callout), .foregroundColor: UIColor.white]
        )
    }
}

final class KanzenPagedReaderViewController: UIViewController, KanzenReaderChildControlling {
    weak var readerDelegate: KanzenReaderChildDelegate?

    private let mode: KanzenReaderMode
    private let pageOffsetKey: String?
    private var sourcePages: [KanzenReaderPage] = []
    private var pages: [KanzenReaderPage] = []
    private var units: [KanzenPagedUnit] = []
    private var controllers: [KanzenReaderPageUnitViewController] = []
    private var currentUnitIndex = 0
    private var splitTask: Task<Void, Never>?
    private lazy var pageViewController = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: mode == .vertical ? .vertical : .horizontal,
        options: nil
    )

    init(mode: KanzenReaderMode, pageOffsetKey: String?) {
        self.mode = mode
        self.pageOffsetKey = pageOffsetKey
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        splitTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyCanvasColor()
        pageViewController.dataSource = self
        pageViewController.delegate = self
        addChild(pageViewController)
        pageViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageViewController.view)
        NSLayoutConstraint.activate([
            pageViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pageViewController.didMove(toParent: self)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, ProfileSettingsStore.active.string(forKey: "Reader.pagedPageLayout") == "auto" else { return }
            let page = self.controllers[safe: self.currentUnitIndex]?.unit.firstPageIndex ?? 0
            self.renderPages(self.sourcePages, startPage: page)
        }
    }

    func setPages(_ pages: [KanzenReaderPage], startPage: Int) {
        sourcePages = pages
        renderPages(pages, startPage: startPage)
    }

    private func renderPages(_ pages: [KanzenReaderPage], startPage: Int) {
        splitTask?.cancel()
        installPages(pages, startPage: startPage)

        guard ProfileSettingsStore.active.bool(forKey: "Reader.splitWideImages"), !pages.isEmpty else { return }
        let target = CGSize(
            width: max(view.bounds.width, UIScreen.main.bounds.width, 1),
            height: max(view.bounds.height, UIScreen.main.bounds.height, 1)
        )
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        let reverse = ProfileSettingsStore.active.bool(forKey: "Reader.reverseSplitOrder")
        splitTask = Task { [weak self, pages, startPage, target, scale, reverse] in
            let result = await Self.splitWidePagesIfNeeded(
                pages,
                startPage: startPage,
                targetSize: target,
                scale: scale,
                reverseOrder: reverse
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.installPages(result.pages, startPage: result.startPage)
            }
        }
    }

    private func installPages(_ pages: [KanzenReaderPage], startPage: Int) {
        self.pages = pages
        self.units = makeUnits(from: pages)
        self.controllers = units.map { KanzenReaderPageUnitViewController(unit: $0) }
        guard !controllers.isEmpty else { return }
        currentUnitIndex = units.firstIndex { $0.contains(page: startPage) } ?? 0
        pageViewController.setViewControllers([controllers[currentUnitIndex]], direction: .forward, animated: false)
        reportCurrentPage()
    }

    func applyReaderSettings(reloadCurrentPages: Bool) {
        applyCanvasColor()
        if reloadCurrentPages {
            let page = controllers[safe: currentUnitIndex]?.unit.firstPageIndex ?? 0
            renderPages(sourcePages, startPage: page)
        } else {
            controllers[safe: currentUnitIndex]?.applyReaderSettings()
        }
    }

    func moveToPage(_ page: Int, animated: Bool) {
        guard let nextIndex = units.firstIndex(where: { $0.contains(page: page) }),
              nextIndex < controllers.count else { return }
        let direction: UIPageViewController.NavigationDirection = nextIndex >= currentUnitIndex ? .forward : .reverse
        currentUnitIndex = nextIndex
        pageViewController.setViewControllers([controllers[nextIndex]], direction: direction, animated: animated && pageTurnsAnimated)
        reportCurrentPage()
    }

    func moveLeft() {
        if mode == .rtl {
            moveUnit(delta: 1)
        } else {
            moveUnit(delta: -1)
        }
    }

    func moveRight() {
        if mode == .rtl {
            moveUnit(delta: -1)
        } else {
            moveUnit(delta: 1)
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: view)
        if let action = KanzenTapZone.action(at: point, in: view.bounds, kind: .paged) {
            performTapZoneAction(action)
            return
        }
        readerDelegate?.readerChildDidRequestOverlayToggle()
    }

    private func makeUnits(from pages: [KanzenReaderPage]) -> [KanzenPagedUnit] {
        let layout = ProfileSettingsStore.active.string(forKey: "Reader.pagedPageLayout") ?? "single"
        let usesDouble = layout == "double" || (layout == "auto" && view.bounds.width > view.bounds.height)
        guard usesDouble else {
            return pages.map { KanzenPagedUnit(pages: [$0], firstPageIndex: $0.index) }
        }

        var result: [KanzenPagedUnit] = []
        var index = 0
        if pageOffsetEnabled, !pages.isEmpty {
            let first = pages[0]
            result.append(KanzenPagedUnit(pages: [first], firstPageIndex: first.index))
            index = 1
        }
        while index < pages.count {
            let first = pages[index]
            let second = index + 1 < pages.count ? pages[index + 1] : nil
            result.append(KanzenPagedUnit(pages: [first, second].compactMap { $0 }, firstPageIndex: first.index))
            index += 2
        }
        return result
    }

    private func moveUnit(delta: Int) {
        let next = min(max(currentUnitIndex + delta, 0), max(controllers.count - 1, 0))
        guard next != currentUnitIndex else { return }
        let direction: UIPageViewController.NavigationDirection = next > currentUnitIndex ? .forward : .reverse
        currentUnitIndex = next
        pageViewController.setViewControllers([controllers[next]], direction: direction, animated: pageTurnsAnimated)
        reportCurrentPage()
    }

    private func performTapZoneAction(_ action: KanzenTapZone.RegionType) {
        let resolved: KanzenTapZone.RegionType
        if ProfileSettingsStore.active.bool(forKey: "Reader.invertTapZones") {
            resolved = action == .left ? .right : .left
        } else {
            resolved = action
        }

        switch resolved {
        case .left:
            moveLeft()
        case .right:
            moveRight()
        }
    }

    private var pageTurnsAnimated: Bool {
        kanzenReaderAnimatesPageTransitions()
    }

    private var pageOffsetEnabled: Bool {
        if let pageOffsetKey,
           let scoped = ProfileSettingsStore.active.object(forKey: pageOffsetKey) as? Bool {
            return scoped
        }
        return ProfileSettingsStore.active.bool(forKey: "Reader.pagedPageOffset")
    }

    private func reportCurrentPage() {
        guard currentUnitIndex < controllers.count else { return }
        let page = controllers[currentUnitIndex].unit.firstPageIndex
        readerDelegate?.readerChildDidChangePage(page, totalPages: pages.count)
        if page >= pages.count - 1 {
            readerDelegate?.readerChildDidReachEnd()
        }
    }

    private func applyCanvasColor() {
        view.backgroundColor = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        pageViewController.view.backgroundColor = view.backgroundColor
        controllers[safe: currentUnitIndex]?.applyReaderSettings()
    }

    private static func splitWidePagesIfNeeded(
        _ pages: [KanzenReaderPage],
        startPage: Int,
        targetSize: CGSize,
        scale: CGFloat,
        reverseOrder: Bool
    ) async -> (pages: [KanzenReaderPage], startPage: Int) {
        var output: [KanzenReaderPage] = []
        var mappedStartPage = 0

        for page in pages {
            if page.index == startPage || output.count == startPage {
                mappedStartPage = output.count
            }

            guard page.isImageLike,
                  let image = try? await ReaderWebtoonImagePipeline.loadImage(
                    for: page.pageData,
                    targetSize: targetSize,
                    scale: scale
                  ),
                  let splitData = splitWideImageData(image, reverseOrder: reverseOrder) else {
                output.append(displayPage(from: page.pageData, index: output.count, sourceID: page.id))
                continue
            }

            for data in splitData {
                output.append(displayPage(from: PageData(content: .imageData(data)), index: output.count, sourceID: page.id))
            }
        }

        return (output, min(mappedStartPage, max(output.count - 1, 0)))
    }

    private static func displayPage(from pageData: PageData, index: Int, sourceID: String) -> KanzenReaderPage {
        KanzenReaderPage(pageData: pageData, index: index, chapterNumber: "display-\(sourceID)")
    }

    private static func splitWideImageData(_ image: UIImage, reverseOrder: Bool) -> [Data]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > height, CGFloat(width) / CGFloat(max(height, 1)) >= 1.18 else { return nil }

        let midpoint = width / 2
        let leftRect = CGRect(x: 0, y: 0, width: midpoint, height: height)
        let rightRect = CGRect(x: midpoint, y: 0, width: width - midpoint, height: height)
        let orderedRects = reverseOrder ? [rightRect, leftRect] : [leftRect, rightRect]
        let parts = orderedRects.compactMap { rect -> Data? in
            guard let cropped = cgImage.cropping(to: rect) else { return nil }
            let part = UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
            return part.jpegData(compressionQuality: 0.96) ?? part.pngData()
        }
        return parts.count == 2 ? parts : nil
    }
}

extension KanzenPagedReaderViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? KanzenReaderPageUnitViewController,
              let current = controllers.firstIndex(of: page) else { return nil }
        let next = mode == .rtl ? current + 1 : current - 1
        guard next >= 0, next < controllers.count else { return nil }
        return controllers[next]
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? KanzenReaderPageUnitViewController,
              let current = controllers.firstIndex(of: page) else { return nil }
        let next = mode == .rtl ? current - 1 : current + 1
        guard next >= 0, next < controllers.count else { return nil }
        return controllers[next]
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, finished,
              let visible = pageViewController.viewControllers?.first as? KanzenReaderPageUnitViewController,
              let index = controllers.firstIndex(of: visible) else { return }
        currentUnitIndex = index
        reportCurrentPage()
    }
}

struct KanzenPagedUnit {
    let pages: [KanzenReaderPage]
    let firstPageIndex: Int

    func contains(page: Int) -> Bool {
        pages.contains { $0.index == page }
    }
}

final class KanzenReaderPageUnitViewController: UIViewController {
    let unit: KanzenPagedUnit
    private let stack = UIStackView()

    init(unit: KanzenPagedUnit) {
        self.unit = unit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        stack.axis = .horizontal
        stack.spacing = 0
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for page in unit.pages {
            let imageView = KanzenReaderImageView()
            imageView.configure(page: page)
            stack.addArrangedSubview(imageView)
        }
    }

    func applyReaderSettings() {
        view.backgroundColor = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        stack.arrangedSubviews.compactMap { $0 as? KanzenReaderImageView }.forEach { $0.applyReaderSettings() }
    }
}

final class KanzenReaderImageView: UIView, UIScrollViewDelegate, UIContextMenuInteractionDelegate {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var page: KanzenReaderPage?
    private var loadTask: Task<Void, Never>?
    private var imageTask: ImageTask?
    private var analysisTask: Task<Void, Never>?
    private lazy var doubleTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        gesture.numberOfTapsRequired = 2
        return gesture
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        applyReaderSettings()
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addGestureRecognizer(doubleTapGesture)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.addInteraction(UIContextMenuInteraction(delegate: self))
        spinner.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("Retry", for: .normal)
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        scrollView.addSubview(imageView)
        addSubview(scrollView)
        addSubview(spinner)
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if scrollView.zoomScale <= 1.01 || imageView.bounds.size == .zero {
            imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
            scrollView.contentSize = imageView.bounds.size
        }
        centerImageView()
    }

    func configure(page: KanzenReaderPage) {
        self.page = page
        applyReaderSettings()
        imageView.image = nil
        configureLiveText(for: nil)
        retryButton.isHidden = true
        scrollView.setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        scrollView.contentSize = imageView.bounds.size
        load()
    }

    func applyReaderSettings() {
        let color = kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
        backgroundColor = color
        scrollView.backgroundColor = color
        imageView.backgroundColor = color
        doubleTapGesture.isEnabled = !ProfileSettingsStore.active.bool(forKey: "Reader.disableDoubleTap")
        if ProfileSettingsStore.active.bool(forKey: "Reader.liveText") {
            configureLiveText(for: imageView.image)
        } else {
            configureLiveText(for: nil)
        }
    }

    private func cancel() {
        imageTask?.cancel()
        loadTask?.cancel()
        analysisTask?.cancel()
    }

    private func load() {
        guard let page else { return }
        cancel()
        spinner.startAnimating()
        retryButton.isHidden = true
        let target = CGSize(width: max(bounds.width, UIScreen.main.bounds.width), height: max(bounds.height, UIScreen.main.bounds.height))
        let scale = window?.screen.scale ?? UIScreen.main.scale
        loadTask = Task { [weak self] in
            do {
                let image = try await ReaderWebtoonImagePipeline.loadImage(
                    for: page.pageData,
                    targetSize: target,
                    scale: scale,
                    taskSink: { [weak self] task in
                        Task { @MainActor in self?.imageTask = task }
                    }
                )
                await MainActor.run {
                    self?.spinner.stopAnimating()
                    self?.imageView.image = image
                    self?.configureLiveText(for: image)
                }
            } catch {
                await MainActor.run {
                    self?.spinner.stopAnimating()
                    self?.retryButton.isHidden = false
                }
            }
        }
    }

    @objc private func retry() {
        load()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard !ProfileSettingsStore.active.bool(forKey: "Reader.disableQuickActions"),
              let image = imageView.image else {
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(image)
            }
            let save = UIAction(title: "Save Image", image: UIImage(systemName: "square.and.arrow.down")) { _ in
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
            let reload = UIAction(title: "Reload Page", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                self?.load()
            }
            return UIMenu(title: "", children: [share, save, reload])
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, imageView.image != nil else { return }
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let targetScale: CGFloat = 2
            let location = gesture.location(in: imageView)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let rect = CGRect(x: location.x - width / 2, y: location.y - height / 2, width: width, height: height)
            scrollView.zoom(to: rect, animated: true)
        }
    }

    private func centerImageView() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    private func share(_ image: UIImage) {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = self
        controller.popoverPresentationController?.sourceRect = bounds
        owningViewController?.present(controller, animated: true)
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController
            }
            responder = current.next
        }
        return nil
    }

    private func configureLiveText(for image: UIImage?) {
        analysisTask?.cancel()
#if canImport(VisionKit)
        guard #available(iOS 16.0, *),
              ProfileSettingsStore.active.bool(forKey: "Reader.liveText"),
              let image else {
            if #available(iOS 16.0, *) {
                removeImageAnalysisInteraction()
            }
            return
        }

        let interaction = imageAnalysisInteraction()
        interaction.analysis = nil
        analysisTask = Task { [weak self, image] in
            do {
                let analyzer = ImageAnalyzer()
                let configuration = ImageAnalyzer.Configuration([.text])
                let analysis = try await analyzer.analyze(image, configuration: configuration)
                await MainActor.run {
                    guard let currentImage = self?.imageView.image, currentImage === image else { return }
                    interaction.analysis = analysis
                    interaction.preferredInteractionTypes = .automatic
                }
            } catch {
                ReaderLogger.shared.log("Reader Live Text skipped: \(error.localizedDescription)", type: "ReaderSettings")
            }
        }
#else
        _ = image
#endif
    }

#if canImport(VisionKit)
    @available(iOS 16.0, *)
    private func imageAnalysisInteraction() -> ImageAnalysisInteraction {
        if let existing = imageView.interactions.compactMap({ $0 as? ImageAnalysisInteraction }).first {
            return existing
        }
        let interaction = ImageAnalysisInteraction()
        imageView.addInteraction(interaction)
        return interaction
    }

    @available(iOS 16.0, *)
    private func removeImageAnalysisInteraction() {
        imageView.interactions.compactMap { $0 as? ImageAnalysisInteraction }.forEach {
            imageView.removeInteraction($0)
        }
    }
#endif
}

final class KanzenTextReaderViewController: UIViewController, KanzenReaderChildControlling, UIScrollViewDelegate {
    weak var readerDelegate: KanzenReaderChildDelegate?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var pages: [KanzenReaderPage] = []
    private var pendingStartPage = 0
    private var lastReportedPage = -1
    private var requestedNextChapterFromOverscroll = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = readerBackgroundColor()
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        restorePendingPageIfNeeded()
    }

    func setPages(_ pages: [KanzenReaderPage], startPage: Int) {
        self.pages = pages
        pendingStartPage = startPage
        lastReportedPage = -1
        requestedNextChapterFromOverscroll = false
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for page in pages {
            let label = UILabel()
            label.numberOfLines = 0
            label.text = page.text ?? ""
            label.font = readerFont()
            label.textColor = readerTextColor()
            label.textAlignment = readerTextAlignment()
            let storedLineSpacing = ProfileSettingsStore.active.object(forKey: "readerLineSpacing") as? Double ?? 1.6
            let lineSpacing = storedLineSpacing.isFinite ? min(max(storedLineSpacing, 1), 3) : 1.6
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = readerTextAlignment()
            paragraph.lineSpacing = CGFloat(max(0, lineSpacing - 1) * Double(label.font.pointSize))
            label.attributedText = NSAttributedString(
                string: page.text ?? "",
                attributes: [.font: label.font as Any, .foregroundColor: readerTextColor(), .paragraphStyle: paragraph]
            )
            let container = UIView()
            container.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            let storedMargin = ProfileSettingsStore.active.object(forKey: "readerMargin") as? Double ?? 4
            let margin = storedMargin.isFinite ? min(max(storedMargin, 0), 30) : 4
            let padding = CGFloat(margin + 16)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24)
            ])
            stack.addArrangedSubview(container)
        }
        view.setNeedsLayout()
        reportCurrentPage(force: true)
    }

    func applyReaderSettings(reloadCurrentPages: Bool) {
        view.backgroundColor = readerBackgroundColor()
        scrollView.backgroundColor = view.backgroundColor
        if reloadCurrentPages {
            setPages(pages, startPage: max(lastReportedPage, pendingStartPage, 0))
        }
    }

    func moveToPage(_ page: Int, animated: Bool) {
        let target = min(max(page, 0), max(pages.count - 1, 0))
        let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let y = pages.count <= 1 ? 0 : maxOffset * (CGFloat(target) / CGFloat(max(pages.count - 1, 1)))
        scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        reportCurrentPage(force: true)
    }

    func moveLeft() {
        moveToPage(max(lastReportedPage - 1, 0), animated: kanzenReaderAnimatesPageTransitions())
    }

    func moveRight() {
        moveToPage(min(lastReportedPage + 1, max(pages.count - 1, 0)), animated: kanzenReaderAnimatesPageTransitions())
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportCurrentPage(force: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        detectEndOverscroll(in: scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        detectEndOverscroll(in: scrollView)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = gesture.location(in: view)
        if let action = KanzenTapZone.action(at: point, in: view.bounds, kind: .text) {
            performTapZoneAction(action)
            return
        }
        readerDelegate?.readerChildDidRequestOverlayToggle()
    }

    private func performTapZoneAction(_ action: KanzenTapZone.RegionType) {
        let resolved: KanzenTapZone.RegionType
        if ProfileSettingsStore.active.bool(forKey: "Reader.invertTapZones") {
            resolved = action == .left ? .right : .left
        } else {
            resolved = action
        }

        switch resolved {
        case .left:
            moveLeft()
        case .right:
            moveRight()
        }
    }

    private func restorePendingPageIfNeeded() {
        guard pendingStartPage > 0 else { return }
        let page = pendingStartPage
        pendingStartPage = 0
        moveToPage(page, animated: false)
    }

    private func reportCurrentPage(force: Bool) {
        guard !pages.isEmpty else { return }
        let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 1)
        let progress = min(max(scrollView.contentOffset.y / maxOffset, 0), 1)
        let page = min(max(Int(round(progress * CGFloat(max(pages.count - 1, 0)))), 0), max(pages.count - 1, 0))
        guard force || page != lastReportedPage else { return }
        lastReportedPage = page
        readerDelegate?.readerChildDidChangePage(page, totalPages: pages.count)
        if page >= pages.count - 1 {
            readerDelegate?.readerChildDidReachEnd()
        }
    }

    private func detectEndOverscroll(in scrollView: UIScrollView) {
        guard !requestedNextChapterFromOverscroll else { return }
        guard lastReportedPage >= pages.count - 1 else { return }
        if ProfileSettingsStore.active.object(forKey: "Reader.verticalInfiniteScroll") != nil,
           !ProfileSettingsStore.active.bool(forKey: "Reader.verticalInfiniteScroll") {
            return
        }
        let maxOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let threshold = max(64, min(scrollView.bounds.height * 0.12, 120))
        guard scrollView.contentOffset.y > maxOffset + threshold else { return }
        if readerDelegate?.readerChildDidRequestNextChapter() == true {
            requestedNextChapterFromOverscroll = true
        }
    }

    private func readerFont() -> UIFont {
        let storedSize = ProfileSettingsStore.active.object(forKey: "readerFontSize") as? Double ?? 16
        let size = CGFloat(storedSize.isFinite ? min(max(storedSize, 12), 32) : 16)
        let weightRaw = ProfileSettingsStore.active.string(forKey: "readerFontWeight") ?? "normal"
        let weight: UIFont.Weight
        switch weightRaw {
        case "500": weight = .medium
        case "700": weight = .bold
        default: weight = .regular
        }

        switch ProfileSettingsStore.active.string(forKey: "readerFontFamily") ?? "-apple-system" {
        case "Georgia":
            return UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size, weight: weight)
        case "Menlo":
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        case "ui-rounded":
            let descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded)
            return descriptor.map { UIFont(descriptor: $0, size: size) } ?? .systemFont(ofSize: size, weight: weight)
        default:
            return .systemFont(ofSize: size, weight: weight)
        }
    }

    private func readerTextAlignment() -> NSTextAlignment {
        switch ProfileSettingsStore.active.string(forKey: "readerTextAlignment") ?? "left" {
        case "center": return .center
        case "right": return .right
        case "justify": return .justified
        default: return .left
        }
    }

    private func readerBackgroundColor() -> UIColor {
        switch ProfileSettingsStore.active.integer(forKey: "readerColorPreset") {
        case 1: return UIColor(red: 0.976, green: 0.945, blue: 0.894, alpha: 1)
        case 2: return UIColor(red: 0.286, green: 0.286, blue: 0.302, alpha: 1)
        case 3: return UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1)
        case 4: return .black
        default: return .white
        }
    }

    private func readerTextColor() -> UIColor {
        switch ProfileSettingsStore.active.integer(forKey: "readerColorPreset") {
        case 1: return UIColor(red: 0.31, green: 0.196, blue: 0.11, alpha: 1)
        case 2: return UIColor(red: 0.843, green: 0.843, blue: 0.847, alpha: 1)
        case 3: return UIColor(red: 0.918, green: 0.918, blue: 0.918, alpha: 1)
        case 4: return .white
        default: return .black
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
