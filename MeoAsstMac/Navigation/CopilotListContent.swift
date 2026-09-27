//
//  CopilotListContent.swift
//  MAA
//
//  Created by hguandl on 2026/8/7.
//

import SwiftUI

struct CopilotListContent: View {
    @Bindable var context: CopilotContext

    var body: some View {
        ForEach($context.copilotList) { $item in
            Toggle(isOn: $item.isOn) {
                HStack(spacing: 6) {
                    Text(item.stageCode)
                        .fontWeight(.medium)
                    if !item.stageName.isEmpty && item.stageName != item.stageCode {
                        Text(item.stageName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if item.isRaid == true {
                        Text("突袭")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .help(item.description)
        }
    }
}

struct CopilotListControls: View {
    @Bindable var context: CopilotContext

    var body: some View {
        HStack(spacing: 12) {
            Button("全选") {
                $context.copilotList.forEach { $i in i.isOn = true }
            }
            .buttonStyle(.borderedProminent)
            Button("取消") {
                $context.copilotList.forEach { $i in i.isOn = false }
            }
            Button("清除") {
                context.copilotList.removeAll()
            }
            .tint(.red)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .onTapGesture {
            context.selection = nil
        }
    }
}

extension CopilotContext.ListItem: CustomStringConvertible {
    var description: String {
        let stage = stageName.isEmpty || stageName == stageCode ? stageCode : "\(stageCode) · \(stageName)"
        if isRaid == true {
            return "\(stage)\(String(localized: "（突袭）"))"
        } else {
            return stage
        }
    }
}

#Preview {
    @Previewable @State var selection = URL?.none
    @Previewable @State var context = CopilotContext()
    NavigationSplitView {
        EmptyView()
    } content: {
        List(selection: $selection) {
            CopilotListContent(context: context)
        }
        .safeAreaInset(edge: .bottom) {
            CopilotListControls(context: context)
        }
    } detail: {
        EmptyView()
    }
}
