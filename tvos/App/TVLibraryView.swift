//
//  TVLibraryView.swift
//  MeloNX tvOS
//
//  Home screen: status of everything a launch needs, then the games.
//  Sized for a 55" TV seen from about 3 m: tvOS focus engine, large type.
//

import SwiftUI
import UIKit

struct TVLibraryView: View {
    @ObservedObject private var emulator = TVEmulator.shared
    @ObservedObject private var controllers = TVControllers.shared

    /// Presents the game full screen (TVRootViewController supplies it).
    let launch: (GameInfo) -> Void

    @State private var notice: Notice?
    @State private var installingFirmware = false

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 48)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                header
                status
                actions
                if emulator.games.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 56) {
                        ForEach(emulator.games) { game in
                            Button { start(game) } label: { GameTile(game: game) }
                                .buttonStyle(.card)
                        }
                    }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .onAppear { emulator.refresh() }
        .alert(item: $notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("확인")))
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MeloNX").font(.system(size: 76, weight: .bold))
            Text("for Apple TV").font(.title2).foregroundColor(.secondary)
            Spacer()
            Text(appVersion).font(.headline).foregroundColor(.secondary)
        }
    }

    private var status: some View {
        HStack(spacing: 28) {
            StatusChip(label: "JIT", value: TVJIT.isAvailable ? "사용 가능" : "없음", ok: TVJIT.isAvailable)
            StatusChip(label: "게임패드", value: controllers.summary, ok: controllers.hasGamepad)
            StatusChip(label: "prod.keys", value: TVPaths.hasProdKeys ? "있음" : "없음", ok: TVPaths.hasProdKeys)
            StatusChip(label: "펌웨어", value: emulator.firmwareVersion.isEmpty ? "미설치" : emulator.firmwareVersion,
                       ok: !emulator.firmwareVersion.isEmpty, optional: true)
            StatusChip(label: "메모리", value: memoryText, ok: TVMemory.raisedLimit, optional: true)
        }
    }

    private var actions: some View {
        HStack(spacing: 32) {
            Button {
                emulator.refresh()
            } label: {
                Label("새로고침", systemImage: "arrow.clockwise")
            }
            if let firmware = TVPaths.firmwareCandidate, emulator.firmwareVersion.isEmpty || installingFirmware {
                Button {
                    install(firmware)
                } label: {
                    Label(installingFirmware ? "펌웨어 설치 중…" : "펌웨어 설치: \(firmware.lastPathComponent)",
                          systemImage: "square.and.arrow.down")
                }
                .disabled(installingFirmware)
            }
            Spacer()
            Text(TVPaths.root.path)
                .font(.callout.monospaced())
                .foregroundColor(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(emulator.loading ? "게임을 찾는 중…" : "게임이 없습니다")
                .font(.title2.bold())
            Group {
                Text("파일 브라우저로 아래 폴더에 복사한 뒤 새로고침을 누르세요.")
                Text("게임 (.nsp .xci .nro)  →  \(TVPaths.roms.path)")
                Text("prod.keys, title.keys  →  \(TVPaths.keys.path)")
                Text("펌웨어 (.zip 또는 폴더)  →  \(TVPaths.firmware.path)")
            }
            .font(.title3)
            .foregroundColor(.secondary)
        }
        .padding(.top, 20)
    }

    // MARK: Actions

    private func start(_ game: GameInfo) {
        if let block = emulator.launchBlock() {
            notice = Notice(title: block.title, message: block.message)
            return
        }
        launch(game)
    }

    private func install(_ url: URL) {
        installingFirmware = true
        emulator.installFirmware(from: url) { error in
            installingFirmware = false
            if let error {
                notice = Notice(title: "펌웨어 설치 실패", message: error)
            } else {
                notice = Notice(title: "펌웨어 설치 완료", message: emulator.firmwareVersion)
            }
        }
    }

    private var memoryText: String {
        let limit = TVMemory.raisedLimit ? "\(TVMemory.requestedLimitMB) MB 한도" : "기본 한도"
        return "\(limit) · RAM \(TVMemory.physicalMB) MB"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}

private struct Notice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct StatusChip: View {
    let label: String
    let value: String
    let ok: Bool
    var optional = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "minus.circle.fill" : "xmark.octagon.fill"))
                    .foregroundColor(ok ? .green : (optional ? .yellow : .red))
                Text(value).font(.headline).lineLimit(1)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
    }
}

private struct GameTile: View {
    let game: GameInfo

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if let icon = game.icon, game.iconData != nil {
                    Image(uiImage: icon).resizable().aspectRatio(1, contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "gamecontroller.fill").font(.system(size: 80)).foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 300, height: 300)
            .clipped()

            VStack(spacing: 4) {
                Text(game.titleName.isEmpty ? game.fileURL.deletingPathExtension().lastPathComponent : game.titleName)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(game.version.isEmpty ? game.titleId : "v\(game.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(width: 300)
            .padding(.bottom, 16)
        }
    }
}
