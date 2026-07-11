import SwiftUI
import Foundation
import Kingfisher
struct contentCell: View {
    @State var title: String
    @State var urlString: String
    @State var width: CGFloat

    
    init(title: String, urlString: String, width: CGFloat) {
        self.title = title
        self.urlString = urlString
        self.width = width

    }
    var body: some View {
        ZStack(alignment: .bottomLeading){
            if let url = URL(string: urlString) {
                
                KFImage(url)
                    .placeholder {
                        EclipseLoadingIndicator()
                    }
                    .fade(duration: 0.25)
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: width, height: width * 1.5)))
                    .resizable()
                    .scaleFactor(UIScreen.main.scale)
                    .interpolation(.low)
                    .aspectRatio(0.72, contentMode: .fill)
                    .frame(width: width, height: width * 1.5)
                    .clipped()
                 
                
                
                    
            } else {
                Rectangle().fill(Color.black).clipped().frame(width: width,height: width * 1.5)
            }
            LinearGradient(
                gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.8)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .frame(maxWidth: .infinity, alignment: .bottom)
            .clipped()
            Text(title).lineLimit(1).foregroundColor(.white)
.cornerRadius(5).padding([.leading, .bottom], 5)
            
        }
        .frame(maxWidth: 150)
        .frame(height: 150 * 1.5)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        
        
        
    }
}
