import SwiftUI
import Kingfisher
import UIKit

private enum StretchyHeaderAmbientColorCache {
    static let values = NSCache<NSString, UIColor>()
}

struct StretchyHeaderView: View {
    let backdropURL: String?
    let isMovie: Bool
    let headerHeight: CGFloat
    let minHeaderHeight: CGFloat
    let onAmbientColorExtracted: ((Color) -> Void)?
    var imageDecodeSize: CGSize? = nil
    
    @State private var localAmbientColor: Color = Color.black

    private var resolvedImageDecodeSize: CGSize {
        imageDecodeSize ?? CGSize(
            width: max(UIScreen.main.bounds.width * UIScreen.main.scale, 1),
            height: max(headerHeight * UIScreen.main.scale, 1)
        )
    }
    
    var body: some View {
        GeometryReader { geometry in
            let frame = geometry.frame(in: .global)
            let deltaY = frame.minY
            let height = headerHeight + max(0, deltaY)
            let offset = min(0, -deltaY)
            
            ZStack(alignment: .bottom) {
                Color.clear
                    .overlay(
                        KFImage(URL(string: backdropURL ?? ""))
                            .setProcessor(DownsamplingImageProcessor(size: resolvedImageDecodeSize))
                            .placeholder {
                                Rectangle()
                                    .fill(Color.gray.opacity(0.3))
                            }
                            .onSuccess { result in
                                updateAmbientColor(from: result.image)
                            }
                            .resizable()
                            .aspectRatio(contentMode: .fill),
                        alignment: .center
                    )
                    .clipped()
                    .frame(height: height)
                    .offset(y: offset)
                
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: localAmbientColor.opacity(0.0), location: 0.0),
                        .init(color: localAmbientColor.opacity(0.1), location: 0.2),
                        .init(color: localAmbientColor.opacity(0.3), location: 0.7),
                        .init(color: localAmbientColor.opacity(0.6), location: 1.0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 0))
            }
        }
        .frame(height: headerHeight)
    }

    private func updateAmbientColor(from image: UIImage) {
        let cacheKey = backdropURL as NSString?
        if let cacheKey,
           let cachedColor = StretchyHeaderAmbientColorCache.values.object(forKey: cacheKey) {
            applyAmbientColor(Color(cachedColor))
            return
        }

        // Dominant-color analysis walks thousands of pixels. Keep it off the main
        // thread so a cached image becoming visible does not stall the hero animation.
        DispatchQueue.global(qos: .utility).async {
            let extractedColor = Color.ambientColor(from: image)
            if let cacheKey {
                StretchyHeaderAmbientColorCache.values.setObject(UIColor(extractedColor), forKey: cacheKey)
            }
            DispatchQueue.main.async {
                applyAmbientColor(extractedColor)
            }
        }
    }

    private func applyAmbientColor(_ color: Color) {
        localAmbientColor = color
        onAmbientColorExtracted?(color)
    }
}
