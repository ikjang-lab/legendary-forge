#pragma once

#include <windows.h>
#include <uiautomation.h>
#include <tlhelp32.h>
#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <unordered_set>
#include <vector>

// Flutter 상태 업데이트를 메인 스레드로 전달하기 위한 커스텀 윈도우 메시지
static constexpr UINT WM_FORGE_STATUS = WM_APP + 200;

struct ForgeStatus {
    std::string text;
    std::string color;
    int level;
    long long gold;
};

class ForgeAutomation {
 public:
    explicit ForgeAutomation(HWND mainHwnd);
    ~ForgeAutomation();

    bool Initialize();
    void Start();
    void Stop();

    int targetLevel = 10;
    int currentLevel = 0;
    long long currentGold = 0;
    std::atomic<bool> isRunning{false};

 private:
    HWND mainHwnd_;
    IUIAutomation* pAuto_ = nullptr;

    std::atomic<bool> shouldStop_{false};
    std::atomic<bool> waitingForResponse_{false};
    std::thread workerThread_;

    std::unordered_set<std::wstring> preCommandSnapshot_;
    std::unordered_set<std::wstring> processedInCycle_;
    std::vector<std::wstring> pendingBotTexts_;

    void RunLoop();
    bool TrySendCommand();
    bool SendViaFocusAndInput(HWND kakaoHwnd);
    bool PollForResponse();
    void HandleBotMessage(const std::wstring& text);

    HWND FindKakaoWindow();
    IUIAutomationElement* GetUIElement(HWND hwnd);
    IUIAutomationElement* FindInputField(IUIAutomationElement* root);
    IUIAutomationElement* FindSendButton(IUIAutomationElement* root);
    void CollectTexts(IUIAutomationElement* elem, std::vector<std::wstring>& out);
    std::unordered_set<std::wstring> CaptureSnapshot();

    void PostStatusToMain(const std::string& text, const std::string& color);
    void SleepInterruptible(int ms);
    static std::string WstrToUtf8(const std::wstring& wstr);
    static std::string FormatGold(long long g);
};
