import SwiftUI

struct CloudHistoryList: View {
  let names: [String]

  var body: some View {
    List {
      Section {
        ForEach(names, id: \.self) { name in
          Text(name)
        }
      } header: {
        Text("Names Claude Code has connected to before. Current state is unknown.")
      }
    }
    .scrollContentBackground(.hidden)
  }
}
