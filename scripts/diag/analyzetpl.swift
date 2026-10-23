import Cocoa
import CoreGraphics

func gray(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let d = ctx.data else { return nil }
    return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: UInt8.self), count: w * h))
}

func stats(_ path: String) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let g = gray(img, 160, 60) else { print("\(path): 读取失败"); return }
    let n = Double(g.count)
    let mean = Double(g.reduce(0) { $0 + Int($1) }) / n
    let varr = g.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / n
    let std = varr.squareRoot()
    let dark = g.filter { Double($0) < mean - 0.8 * std }.count
    let light = g.filter { Double($0) > mean + 0.8 * std }.count
    print(String(format: "%@  mean=%.1f std=%.1f 暗侧=%d 亮侧=%d", (path as NSString).lastPathComponent, mean, std, dark, light))
}

let dir = "/Users/zhuxiaoyu/Library/Application Support/CodexRetry"
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".png") }.sorted() ?? []
for f in files { stats(dir + "/" + f) }
