//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    var isSystemImage: Bool = true
    var iconSize: CGFloat = 16
    let selected: Bool
    let onClick: () -> Void
    
    var body: some View {
        Button(action: onClick) {
            iconImage
                .padding(.horizontal, 15)
                .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private var iconImage: some View {
        if isSystemImage {
            Image(systemName: icon)
        } else {
            // Template asset drawn at `iconSize` but laid out in a 16pt slot like the SF Symbols,
            // so padded icons can be drawn larger without widening their tab.
            Image(icon)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .frame(width: 16, height: 16)
        }
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}
