import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        SearchFormView(viewModel: viewModel)
    }
}
