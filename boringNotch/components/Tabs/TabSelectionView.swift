//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    /// SF Symbol name, or the name of a template image in Assets.xcassets when `isSystemImage` is false.
    let icon: String
    var isSystemImage: Bool = true
    /// Drawn size of an asset icon. Menu-bar template images pad their glyph differently, so each
    /// gets a size that makes the visible glyph match the SF Symbols (~15pt).
    var iconSize: CGFloat = 16
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    // Menu-bar icons of the ChatGPT (Codex) and Claude desktop apps.
    TabModel(label: "Codex", icon: "codex", isSystemImage: false, iconSize: 16, view: .codex),
    TabModel(label: "Claude", icon: "claude", isSystemImage: false, iconSize: 22, view: .claude)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            // The Shelf tab only exists while the Shelf feature is enabled.
            ForEach(tabs.filter { $0.view != .shelf || Defaults[.boringShelf] }) { tab in
                    TabButton(label: tab.label, icon: tab.icon, isSystemImage: tab.isSystemImage, iconSize: tab.iconSize, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
