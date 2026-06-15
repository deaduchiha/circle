import Charts
import CoreProxy
import SwiftUI

struct BandwidthGraphView: View {
  let samples: [BandwidthSample]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Bandwidth")
        .font(.headline)

      if samples.isEmpty {
        Text("Traffic graph appears after the proxy starts.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
      } else {
        Chart(samples) { sample in
          LineMark(
            x: .value("Time", sample.timestamp),
            y: .value("In", sample.bytesInPerSecond)
          )
          .foregroundStyle(.blue)
          .interpolationMethod(.catmullRom)

          LineMark(
            x: .value("Time", sample.timestamp),
            y: .value("Out", sample.bytesOutPerSecond)
          )
          .foregroundStyle(.orange)
          .interpolationMethod(.catmullRom)
        }
        .chartYAxisLabel("bytes/s")
        .frame(height: 120)
      }
    }
    .padding(.horizontal)
  }
}
