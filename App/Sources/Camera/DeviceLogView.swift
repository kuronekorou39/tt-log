import Charts
import SwiftUI

/// 温度・電池の推移のグラフ。録画していた時間は赤く塗る。
struct DeviceLogChart: View {
    let samples: [DeviceSample]

    private struct Span: Identifiable {
        var start: Date
        var end: Date
        var id: Date { start }
    }

    /// 録画していた時間のまとまり。
    private var recordingSpans: [Span] {
        var spans: [Span] = []
        var current: Span?
        for s in samples {
            if s.recording {
                if current == nil { current = Span(start: s.at, end: s.at) }
                current?.end = s.at
            } else if let c = current {
                spans.append(Span(start: c.start, end: s.at))
                current = nil
            }
        }
        if let current { spans.append(current) }
        return spans
    }

    var body: some View {
        let spans = recordingSpans
        VStack(alignment: .leading, spacing: 12) {
            if let first = samples.first, let last = samples.last {
                Text(summary(first: first, last: last))
                    .font(.callout)
            }
            Text("温度（iPhone が知らせる4段階）").font(.subheadline.bold())
            Chart {
                ForEach(spans) { span in
                    RectangleMark(xStart: .value("開始", span.start), xEnd: .value("終了", span.end),
                                  yStart: .value("下", 0), yEnd: .value("上", 3))
                        .foregroundStyle(.red.opacity(0.12))
                }
                ForEach(samples) { s in
                    LineMark(x: .value("時刻", s.at), y: .value("温度", s.thermal))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(.orange)
                }
            }
            .chartYScale(domain: 0...3)
            .chartYAxis {
                AxisMarks(values: [0, 1, 2, 3]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let i = value.as(Int.self), DeviceSample.thermalTitles.indices.contains(i) {
                            Text(DeviceSample.thermalTitles[i])
                        }
                    }
                }
            }
            .frame(height: 140)

            Text("電池（%）").font(.subheadline.bold())
            Chart {
                ForEach(spans) { span in
                    RectangleMark(xStart: .value("開始", span.start), xEnd: .value("終了", span.end),
                                  yStart: .value("下", 0), yEnd: .value("上", 100))
                        .foregroundStyle(.red.opacity(0.12))
                }
                ForEach(samples.filter { $0.battery != nil }) { s in
                    LineMark(x: .value("時刻", s.at), y: .value("電池", s.battery ?? 0))
                        .foregroundStyle(.green)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 140)

            Label("赤い帯は録画していた時間", systemImage: "square.fill")
                .font(.caption)
                .foregroundStyle(.red.opacity(0.6))
        }
    }

    private func summary(first: DeviceSample, last: DeviceSample) -> String {
        var items: [String] = []
        let minutes = Int(last.at.timeIntervalSince(first.at) / 60)
        items.append("\(minutes)分間")
        if let maxThermal = samples.map(\.thermal).max() {
            items.append("最高 \(DeviceSample.thermalTitles[maxThermal])")
        }
        if let b0 = first.battery, let b1 = last.battery {
            items.append("電池 \(b0)% → \(b1)%")
        }
        let recorded = recordingSpans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        items.append("録画 約\(Int(recorded / 60))分")
        return items.joined(separator: "　")
    }
}

/// 日ごとの温度・電池の記録の一覧。CSV は共有で PC などへ送れる。
struct DeviceLogListView: View {
    let log: DeviceLog

    var body: some View {
        let days = log.days()
        List {
            if days.isEmpty {
                Text("まだ記録がありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(days, id: \.self) { url in
                NavigationLink(DeviceLog.dayTitle(url)) {
                    DeviceLogDayView(url: url)
                }
            }
        }
        .navigationTitle("温度・電池の記録")
    }
}

private struct DeviceLogDayView: View {
    let url: URL

    var body: some View {
        let samples = DeviceLog.load(url)
        ScrollView {
            if samples.isEmpty {
                Text("読めませんでした").foregroundStyle(.secondary)
            } else {
                DeviceLogChart(samples: samples).padding()
            }
        }
        .navigationTitle(DeviceLog.dayTitle(url))
        .toolbar {
            ShareLink(item: url) { Label("CSV を送る", systemImage: "square.and.arrow.up") }
        }
    }
}
