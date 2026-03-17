import Cocoa
import ApplicationServices

class ForgeAutomationService {
    private let kakaoBundleId = "com.kakao.KakaoTalkMac"

    var isRunning = false
    var targetLevel = 10
    var currentLevel = 0
    var currentGold: Int64 = 0
    var onStatusUpdate: (([String: Any]) -> Void)?

    private var waitingForResponse = false
    private var preCommandSnapshot = Set<String>()
    private var processedInCycle = Set<String>()
    private var pendingBotTexts = [String]()

    private var commandTimer: Timer?
    private var timeoutTimer: Timer?
    private var pollTimer: Timer?

    func start() {
        guard !isRunning else { return }
        if currentLevel >= targetLevel {
            sendStatus("이미 목표 달성!", "#FFD700")
            return
        }
        isRunning = true
        sendStatus("강화 시작...", "#00FF88")
        scheduleCommand(after: 0.6)
    }

    func stop() {
        isRunning = false
        waitingForResponse = false
        pendingBotTexts.removeAll()
        processedInCycle.removeAll()
        preCommandSnapshot.removeAll()
        commandTimer?.invalidate(); commandTimer = nil
        timeoutTimer?.invalidate(); timeoutTimer = nil
        pollTimer?.invalidate();    pollTimer = nil
        sendStatus("중지됨", "#AAAAAA")
    }

    private func scheduleCommand(after delay: TimeInterval) {
        commandTimer?.invalidate()
        commandTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.trySendCommand()
        }
    }

    private func trySendCommand() {
        guard isRunning else { return }
        preCommandSnapshot = captureSnapshot()
        processedInCycle.removeAll()
        pendingBotTexts.removeAll()

        guard let app = findKakaoApp() else {
            sendStatus("카카오톡 실행 중이 아닙니다", "#FF6666")
            scheduleCommand(after: 2.0)
            return
        }
        guard let window = getWindow(of: app) else {
            sendStatus("카카오톡 채팅방을 열어주세요", "#FF6666")
            scheduleCommand(after: 2.0)
            return
        }
        guard let inputField = findInputField(in: window) else {
            sendStatus("입력창 탐색 재시도...", "#FFAA00")
            scheduleCommand(after: 1.5)
            return
        }

        AXUIElementSetAttributeValue(inputField, kAXValueAttribute as CFString, "/강화" as CFTypeRef)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.pressSend(window: window, inputField: inputField)
        }
    }

    private func pressSend(window: AXUIElement, inputField: AXUIElement) {
        if let btn = findSendButton(in: window) {
            AXUIElementPerformAction(btn, kAXPressAction as CFString)
            startPolling()
            return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(inputField, &pid)
        AXUIElementSetAttributeValue(inputField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            if let src = CGEventSource(stateID: .hidSystemState) {
                let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(0x24), keyDown: true)
                let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(0x24), keyDown: false)
                keyDown?.postToPid(pid)
                keyUp?.postToPid(pid)
            }
            self.startPolling()
        }
    }

    private func startPolling() {
        waitingForResponse = true
        sendStatus("💬 응답 대기...", "#AAAAFF")

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.scanForBotResponse()
        }
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 7.0, repeats: false) { [weak self] _ in
            guard let self, self.waitingForResponse else { return }
            self.waitingForResponse = false
            self.pollTimer?.invalidate(); self.pollTimer = nil
            self.sendStatus("응답 없음 - 재시도", "#FFAA00")
            self.scheduleCommand(after: 1.5)
        }
    }

    private func scanForBotResponse() {
        guard waitingForResponse else { return }
        guard let app = findKakaoApp(), let window = getWindow(of: app) else { return }

        var texts = [String]()
        collectTexts(from: window, into: &texts)

        var foundGold = false
        for text in texts {
            guard !preCommandSnapshot.contains(text) else { continue }
            guard processedInCycle.insert(text).inserted else { continue }
            pendingBotTexts.append(text)
            if text.contains("남은 골드") || text.contains("보유 골드") { foundGold = true }
        }

        if foundGold {
            pollTimer?.invalidate();    pollTimer = nil
            timeoutTimer?.invalidate(); timeoutTimer = nil
            let combined = pendingBotTexts.joined(separator: "\n")
            pendingBotTexts.removeAll()
            handleBotMessage(combined)
        }
    }

    private func handleBotMessage(_ text: String) {
        waitingForResponse = false

        let resultType: String
        if text.contains("강화 성공")      { resultType = "success" }
        else if text.contains("강화 파괴") { resultType = "destroy"  }
        else                               { resultType = "maintain" }

        if resultType == "success" {
            if let range = text.range(of: #"→ \+(\d+)"#, options: .regularExpression) {
                let matched = String(text[range])
                if let levelStr = matched.components(separatedBy: "+").last, let level = Int(levelStr) {
                    currentLevel = level
                } else { currentLevel += 1 }
            } else { currentLevel += 1 }
        } else if resultType == "destroy" {
            currentLevel = 0
        }

        let goldPattern = #"(?:남은|보유) 골드: ([0-9,]+)G"#
        if let range = text.range(of: goldPattern, options: .regularExpression) {
            let matched = String(text[range])
            if let goldPart = matched.components(separatedBy: ": ").last {
                let digits = goldPart.replacingOccurrences(of: "G", with: "").replacingOccurrences(of: ",", with: "")
                currentGold = Int64(digits) ?? currentGold
            }
        }

        let statusText: String; let statusColor: String
        switch resultType {
        case "success": statusText = "✨ 성공! → +\(currentLevel)"; statusColor = "#00FF88"
        case "destroy": statusText = "💥 파괴... +0으로 리셋";        statusColor = "#FF4444"
        default:        statusText = "💦 유지 +\(currentLevel)";       statusColor = "#4488FF"
        }
        sendStatus(statusText, statusColor)

        guard isRunning else { return }
        if currentLevel >= targetLevel {
            sendStatus("🎉 +\(targetLevel) 달성!", "#FFD700")
            stop(); return
        }
        scheduleCommand(after: 0.8)
    }

    private func findKakaoApp() -> AXUIElement? {
        guard let kakao = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == kakaoBundleId }) else { return nil }
        return AXUIElementCreateApplication(kakao.processIdentifier)
    }

    private func getWindow(of app: AXUIElement) -> AXUIElement? {
        var val: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &val) == .success {
            return (val as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &val) == .success,
           let arr = val as? [AXUIElement], let first = arr.first { return first }
        return nil
    }

    private func findInputField(in element: AXUIElement) -> AXUIElement? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let r = role as? String ?? ""
        if r == kAXTextFieldRole || r == kAXTextAreaRole {
            var enabled: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
            if (enabled as? Bool) == true { return element }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let arr = children as? [AXUIElement] else { return nil }
        for child in arr { if let found = findInputField(in: child) { return found } }
        return nil
    }

    private func findSendButton(in element: AXUIElement) -> AXUIElement? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXButtonRole {
            for attr in [kAXDescriptionAttribute, kAXTitleAttribute] as [CFString] {
                var val: CFTypeRef?
                AXUIElementCopyAttributeValue(element, attr, &val)
                let s = (val as? String ?? "").lowercased()
                if s.contains("전송") || s.contains("보내기") || s.contains("send") { return element }
            }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let arr = children as? [AXUIElement] else { return nil }
        for child in arr { if let found = findSendButton(in: child) { return found } }
        return nil
    }

    private func captureSnapshot() -> Set<String> {
        guard let app = findKakaoApp(), let window = getWindow(of: app) else { return [] }
        var texts = [String]()
        collectTexts(from: window, into: &texts)
        return Set(texts)
    }

    private func collectTexts(from element: AXUIElement, into texts: inout [String]) {
        for attr in [kAXValueAttribute, kAXDescriptionAttribute] as [CFString] {
            var val: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attr, &val)
            if let s = val as? String, s.count > 4 { texts.append(s) }
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let arr = children as? [AXUIElement] else { return }
        for child in arr { collectTexts(from: child, into: &texts) }
    }

    private func sendStatus(_ text: String, _ color: String) {
        onStatusUpdate?(["text": text, "color": color, "level": currentLevel, "gold": currentGold])
    }
}
