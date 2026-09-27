//
//  CopilotConfiguration.swift
//  MAA
//
//  Created by hguandl on 17/4/2023.
//

import Foundation
import Observation

struct CopilotConfiguration: Codable, Hashable {
    var enable = true

    var filename: String?

    struct CopilotItem: Codable, Hashable {
        let id: Int
        let filename: String
        let nav_name_override: String?
        let is_raid: Bool
    }

    var copilot_list = [CopilotItem]()

    var enableLoop = false
    var loop_times = 1

    var use_sanity_potion = false

    var formation = false
    var formation_index = 0

    struct UserUnit: Codable, Hashable {
        let name: String
        let skill: Int
    }

    var enableUserAdditional = false
    var user_additional = [UserUnit]()

    var add_trust = false
    var ignore_requirements = false

    enum SupportUnitUsage: Int, CaseIterable, Codable {
        /// 不加助战干员
        case none = 0
        /// 如果仅缺一名干员则尝试补助战
        case whenNeeded = 1
        /// 如果仅缺一名干员则尝试补助战，如无缺失则随机加一个助战干员
        case random = 3
        /// 如果仅缺一名干员则尝试补助战，如无缺失则使用指定助战干员
        case specific = 2
    }

    var support_unit_usage = SupportUnitUsage.none
    var support_unit_name = ""
}

extension CopilotConfiguration.SupportUnitUsage: Identifiable {
    var id: Int {
        rawValue
    }
}

extension CopilotConfiguration.SupportUnitUsage: CustomStringConvertible {
    var description: String {
        switch self {
        case .none:
            return String(localized: "不借", comment: "")
        case .whenNeeded:
            return String(localized: "补漏", comment: "")
        case .specific:
            return String(localized: "指定", comment: "")
        case .random:
            return String(localized: "随机", comment: "")
        }
    }
}

struct VideoRecognitionConfiguration: Codable {
    var enable = true
    var filename: String

    var params: String? {
        try? jsonString()
    }
}

enum CopilotCategory: String, CaseIterable {
    case bundled
    case external
    case list
}

@Observable final class CopilotContext {
    var config = CopilotConfiguration()

    @ObservationIgnored
    @Defaults("CopilotContentCategory")
    var category = CopilotCategory.bundled

    @ObservationIgnored @Defaults("CopilotTaskList") private var savedCopilotList = Data()
    @ObservationIgnored @Defaults("CopilotTaskListSet") private var savedCopilotSet = Data()

    init() {
        if let list = try? JSONDecoder().decode([ListItem].self, from: savedCopilotList) {
            copilotList = list
        }
        if let set = try? JSONDecoder().decode(CopilotSet.self, from: savedCopilotSet) {
            copilotSet = set
        }
    }

    struct ItemID: Hashable {
        let url: URL
        let isRaid: Bool?
    }

    @ObservationIgnored @MainActor private var contentUpdateTask: Task<Void, Never>?

    @MainActor var selection: ItemID? {
        didSet {
            guard oldValue != selection else {
                return
            }
            contentUpdateTask?.cancel()
            guard let url = selection?.url else {
                content = nil
                return
            }
            content = .pending
            contentUpdateTask = Task {
                let newContent = await Content(url: url)
                guard !Task.isCancelled else { return }
                content = newContent
                contentUpdateTask = nil
            }
        }
    }

    enum Content: Equatable {
        case pending
        case copilot(URL, MAACopilot.Kind, MAACopilot)
        case set(URL, CopilotSetData)
        case directory
        case invalid
    }

    private(set) var content: Content?

    struct CopilotSet: Codable {
        let kind: MAACopilot.Kind
        let data: CopilotSetData
    }

    private(set) var copilotSet: CopilotSet? {
        didSet {
            savedCopilotSet = (try? JSONEncoder().encode(copilotSet)) ?? Data()
        }
    }

    struct ListItem: Codable, Identifiable {
        let url: URL
        let stageCode: String
        let stageName: String
        var isRaid: Bool?

        var isOn = false

        var id: ItemID {
            .init(url: url, isRaid: isRaid)
        }
    }

    var copilotList = [ListItem]() {
        didSet {
            savedCopilotList = (try? JSONEncoder().encode(copilotList)) ?? Data()
            if copilotList.isEmpty {
                copilotSet = nil
            }
        }
    }
}

extension CopilotContext {
    @discardableResult
    nonisolated(nonsending) func addToList(at url: URL) async -> Bool {
        guard let copilot = MAACopilot(url: url),
            let (kind, items) = await copilot.listItems(at: url),
            !items.isEmpty,
            copilotSet?.kind == nil || copilotSet?.kind == kind
        else {
            return false
        }

        if copilotSet == nil {
            copilotSet = .init(
                kind: kind,
                data: .init(name: String(localized: "自定义作业列表"), description: "", copilot_ids: []))
        }
        let existing = Set(copilotList.map(\.id))
        copilotList.append(contentsOf: items.filter { !existing.contains($0.id) })
        return true
    }

    nonisolated(nonsending) func updateSet(at url: URL, set: CopilotSetData) async {
        guard let (kind, list) = await set.copilotList(at: url) else {
            return
        }

        self.copilotSet = .init(kind: kind, data: set)
        self.copilotList = list
    }

    nonisolated(nonsending) func updateSet(at url: URL) async {
        guard let set = CopilotSetData(atDirectory: url) else {
            return
        }
        await updateSet(at: url, set: set)
    }
}

extension CopilotContext.Content {
    @concurrent init(url: URL) async {
        if url.isDirectory {
            if let set = CopilotSetData(atDirectory: url) {
                self = .set(url, set)
            } else {
                self = .directory
            }
        } else {
            if let copilot = MAACopilot(url: url) {
                let kind = await copilot.kind
                self = .copilot(url, kind, copilot)
            } else {
                self = .invalid
            }
        }
    }
}

extension CopilotSetData {
    func copilotList(at url: URL) async -> (MAACopilot.Kind, [CopilotContext.ListItem])? {
        guard url.isDirectory else { return nil }

        var copilotList = [CopilotContext.ListItem]()

        var lastCopilotKind: MAACopilot.Kind?

        for copilotID in copilot_ids {
            let url = url.appending(path: "\(copilotID).json")
            guard let copilot = MAACopilot(url: url),
                let (kind, items) = await copilot.listItems(at: url)
            else {
                return nil
            }

            if lastCopilotKind == nil {
                lastCopilotKind = kind
            } else if lastCopilotKind != kind {
                print("Mixed copilot kind in list")
                return nil
            }

            copilotList.append(contentsOf: items)
        }

        return (lastCopilotKind ?? .regular, copilotList)
    }
}

extension MAACopilot {
    enum Kind: String, Codable, Hashable {
        case regular
        case sss
        case paradox
    }

    func listItems(at url: URL) async -> (Kind, [CopilotContext.ListItem])? {
        guard let level = await MAAProvider.shared.mapLevel(matching: stage_name) else {
            return nil
        }
        let raidOptions: [Bool?]
        switch difficulty {
        case nil, 0:
            raidOptions = [nil]
        case 1:
            raidOptions = [false]
        case 2:
            raidOptions = [true]
        case 3:
            raidOptions = [false, true]
        default:
            raidOptions = []
        }
        return (
            kind(code: level.code),
            raidOptions.map {
                .init(url: url, stageCode: level.code, stageName: level.name, isRaid: $0, isOn: true)
            }
        )
    }

    func kind(code: String) -> Kind {
        if type == "SSS" {
            return .sss
        }
        if code.starts(with: "mem_") {
            return .paradox
        }
        return .regular
    }

    var kind: Kind {
        get async {
            if type == "SSS" {
                return .sss
            }
            let code = await MAAProvider.shared.mapLevelCode(matching: stage_name)
            if let code, code.starts(with: "mem_") {
                return .paradox
            }
            return .regular
        }
    }
}
