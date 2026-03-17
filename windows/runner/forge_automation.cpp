#include "forge_automation.h"

#include <combaseapi.h>
#include <psapi.h>
#include <sstream>
#include <regex>

#pragma comment(lib, "uiautomationcore.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

ForgeAutomation::ForgeAutomation(HWND mainHwnd) : mainHwnd_(mainHwnd) {}

ForgeAutomation::~ForgeAutomation() {
    Stop();
    if (pAuto_) { pAuto_->Release(); pAuto_ = nullptr; }
    CoUninitialize();
}

bool ForgeAutomation::Initialize() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return false;
    hr = CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                          CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pAuto_));
    return SUCCEEDED(hr);
}

void ForgeAutomation::Start() {
    if (isRunning.load()) return;
    if (currentLevel >= targetLevel) {
        PostStatusToMain("이미 목표 달성!", "#FFD700");
        return;
    }
    isRunning = true;
    shouldStop_ = false;
    if (workerThread_.joinable()) workerThread_.join();
    workerThread_ = std::thread(&ForgeAutomation::RunLoop, this);
}

void ForgeAutomation::Stop() {
    isRunning = false;
    shouldStop_ = true;
    waitingForResponse_ = false;
    if (workerThread_.joinable()) workerThread_.join();
    PostStatusToMain("중지됨", "#AAAAAA");
}

// ── Worker Loop ───────────────────────────────────────────────────────────────

void ForgeAutomation::RunLoop() {
    // 작업자 스레드에서 COM 초기화 (멀티스레드 모델)
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    PostStatusToMain("강화 시작...", "#00FF88");
    SleepInterruptible(600);

    while (!shouldStop_.load() && isRunning.load()) {
        if (!TrySendCommand()) continue;
        if (!PollForResponse()) continue;
        SleepInterruptible(800);
    }

    CoUninitialize();
}

bool ForgeAutomation::TrySendCommand() {
    preCommandSnapshot_ = CaptureSnapshot();
    processedInCycle_.clear();
    pendingBotTexts_.clear();

    HWND kakaoHwnd = FindKakaoWindow();
    if (!kakaoHwnd) {
        PostStatusToMain("카카오톡을 찾을 수 없음", "#FF6666");
        SleepInterruptible(2000);
        return false;
    }

    IUIAutomationElement* rootElem = GetUIElement(kakaoHwnd);
    if (!rootElem) { SleepInterruptible(1500); return false; }

    IUIAutomationElement* inputElem = FindInputField(rootElem);
    rootElem->Release();

    if (!inputElem) {
        PostStatusToMain("입력창 탐색 재시도...", "#FFAA00");
        SleepInterruptible(1500);
        return false;
    }

    // 텍스트 설정 (IValuePattern)
    IValueProvider* pValue = nullptr;
    if (SUCCEEDED(inputElem->GetCurrentPattern(UIA_ValuePatternId, (IUnknown**)&pValue)) && pValue) {
        pValue->SetValue(L"/강화");
        pValue->Release();
    }
    Sleep(250);

    // 전송 버튼 클릭 시도
    bool sent = false;
    IUIAutomationElement* rootElem2 = GetUIElement(kakaoHwnd);
    if (rootElem2) {
        IUIAutomationElement* sendBtn = FindSendButton(rootElem2);
        if (sendBtn) {
            IInvokeProvider* pInvoke = nullptr;
            if (SUCCEEDED(sendBtn->GetCurrentPattern(UIA_InvokePatternId, (IUnknown**)&pInvoke)) && pInvoke) {
                pInvoke->Invoke();
                pInvoke->Release();
                sent = true;
            }
            sendBtn->Release();
        }
        rootElem2->Release();
    }

    // 폴백: 입력창 HWND에 Return 키 전송
    if (!sent) {
        UIA_HWND inputHwnd = nullptr;
        if (SUCCEEDED(inputElem->get_CurrentNativeWindowHandle(&inputHwnd)) && inputHwnd) {
            PostMessage((HWND)inputHwnd, WM_KEYDOWN, VK_RETURN, 0x001C0001);
            PostMessage((HWND)inputHwnd, WM_KEYUP,   VK_RETURN, 0xC01C0001);
            sent = true;
        }
    }

    inputElem->Release();

    if (!sent) {
        PostStatusToMain("전송 실패 - 재시도", "#FFAA00");
        SleepInterruptible(1500);
        return false;
    }
    return true;
}

bool ForgeAutomation::PollForResponse() {
    PostStatusToMain("💬 응답 대기...", "#AAAAFF");
    ULONGLONG start = GetTickCount64();

    while (!shouldStop_.load() && isRunning.load()) {
        if (GetTickCount64() - start > 7000) {
            PostStatusToMain("응답 없음 - 재시도", "#FFAA00");
            SleepInterruptible(1500);
            return false;
        }

        HWND kakaoHwnd = FindKakaoWindow();
        if (kakaoHwnd) {
            IUIAutomationElement* root = GetUIElement(kakaoHwnd);
            if (root) {
                std::vector<std::wstring> allTexts;
                CollectTexts(root, allTexts);
                root->Release();

                bool foundGold = false;
                for (const auto& text : allTexts) {
                    if (preCommandSnapshot_.count(text)) continue;
                    if (!processedInCycle_.insert(text).second) continue;
                    pendingBotTexts_.push_back(text);
                    if (text.find(L"남은 골드") != std::wstring::npos ||
                        text.find(L"보유 골드") != std::wstring::npos) {
                        foundGold = true;
                    }
                }

                if (foundGold) {
                    std::wstring combined;
                    for (const auto& t : pendingBotTexts_) combined += t + L"\n";
                    pendingBotTexts_.clear();
                    HandleBotMessage(combined);
                    return true;
                }
            }
        }
        Sleep(300);
    }
    return false;
}

void ForgeAutomation::HandleBotMessage(const std::wstring& text) {
    std::string resultType;
    if (text.find(L"강화 성공") != std::wstring::npos)      resultType = "success";
    else if (text.find(L"강화 파괴") != std::wstring::npos) resultType = "destroy";
    else                                                     resultType = "maintain";

    if (resultType == "success") {
        // → +N 파싱
        std::wregex re(L"→ \\+(\\d+)");
        std::wsmatch m;
        if (std::regex_search(text, m, re)) {
            currentLevel = std::stoi(m[1].str());
        } else {
            currentLevel++;
        }
    } else if (resultType == "destroy") {
        currentLevel = 0;
    }

    // 골드 파싱
    std::wregex goldRe(L"(?:남은|보유) 골드: ([0-9,]+)G");
    std::wsmatch gm;
    if (std::regex_search(text, gm, goldRe)) {
        std::wstring gs = gm[1].str();
        gs.erase(std::remove(gs.begin(), gs.end(), L','), gs.end());
        currentGold = std::stoll(gs);
    }

    std::string statusText, statusColor;
    if (resultType == "success") {
        statusText  = std::string("✨ 성공! → +") + std::to_string(currentLevel);
        statusColor = "#00FF88";
    } else if (resultType == "destroy") {
        statusText  = "💥 파괴... +0으로 리셋";
        statusColor = "#FF4444";
    } else {
        statusText  = std::string("💦 유지 +") + std::to_string(currentLevel);
        statusColor = "#4488FF";
    }

    PostStatusToMain(statusText, statusColor);

    if (!isRunning.load()) return;
    if (currentLevel >= targetLevel) {
        std::string msg = std::string("🎉 +") + std::to_string(targetLevel) + " 달성!";
        PostStatusToMain(msg, "#FFD700");
        isRunning = false;
    }
}

// ── UI Automation Helpers ────────────────────────────────────────────────────

HWND ForgeAutomation::FindKakaoWindow() {
    // KakaoTalk.exe 프로세스 탐색
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W pe; pe.dwSize = sizeof(pe);
    DWORD pid = 0;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, L"KakaoTalk.exe") == 0) {
                pid = pe.th32ProcessID; break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    if (pid == 0) return nullptr;

    // 해당 프로세스의 최상위 창 탐색 (입력창이 있는 채팅방 창 우선)
    struct SearchData { DWORD pid; HWND best; HWND first; };
    SearchData data{pid, nullptr, nullptr};

    EnumWindows([](HWND hwnd, LPARAM lp) -> BOOL {
        auto* d = reinterpret_cast<SearchData*>(lp);
        DWORD wpid = 0;
        GetWindowThreadProcessId(hwnd, &wpid);
        if (wpid != d->pid || !IsWindowVisible(hwnd)) return TRUE;

        wchar_t title[256] = {};
        GetWindowTextW(hwnd, title, 256);
        if (wcslen(title) == 0) return TRUE;

        if (d->first == nullptr) d->first = hwnd;
        // 채팅방 창 우선 (타이틀이 있는 서브 창)
        if (d->best == nullptr && wcslen(title) > 0) d->best = hwnd;
        return TRUE;
    }, (LPARAM)&data);

    return data.best ? data.best : data.first;
}

IUIAutomationElement* ForgeAutomation::GetUIElement(HWND hwnd) {
    if (!pAuto_ || !hwnd) return nullptr;
    IUIAutomationElement* elem = nullptr;
    pAuto_->ElementFromHandle(hwnd, &elem);
    return elem;
}

IUIAutomationElement* ForgeAutomation::FindInputField(IUIAutomationElement* root) {
    if (!root || !pAuto_) return nullptr;

    VARIANT varType; varType.vt = VT_I4; varType.lVal = UIA_EditControlTypeId;
    IUIAutomationCondition* cond = nullptr;
    pAuto_->CreatePropertyCondition(UIA_ControlTypePropertyId, varType, &cond);

    IUIAutomationElement* found = nullptr;
    root->FindFirst(TreeScope_Descendants, cond, &found);
    cond->Release();
    return found;
}

IUIAutomationElement* ForgeAutomation::FindSendButton(IUIAutomationElement* root) {
    if (!root || !pAuto_) return nullptr;

    VARIANT varType; varType.vt = VT_I4; varType.lVal = UIA_ButtonControlTypeId;
    IUIAutomationCondition* cond = nullptr;
    pAuto_->CreatePropertyCondition(UIA_ControlTypePropertyId, varType, &cond);

    IUIAutomationElementArray* buttons = nullptr;
    root->FindAll(TreeScope_Descendants, cond, &buttons);
    cond->Release();
    if (!buttons) return nullptr;

    int count = 0;
    buttons->get_Length(&count);
    for (int i = 0; i < count; i++) {
        IUIAutomationElement* btn = nullptr;
        buttons->GetElement(i, &btn);
        if (!btn) continue;

        BSTR name = nullptr;
        btn->get_CurrentName(&name);
        if (name) {
            std::wstring s(name);
            SysFreeString(name);
            if (s.find(L"전송") != std::wstring::npos ||
                s.find(L"보내기") != std::wstring::npos ||
                s.find(L"send") != std::wstring::npos ||
                s.find(L"Send") != std::wstring::npos) {
                buttons->Release();
                return btn;
            }
        }
        btn->Release();
    }
    buttons->Release();
    return nullptr;
}

void ForgeAutomation::CollectTexts(IUIAutomationElement* elem,
                                    std::vector<std::wstring>& out) {
    if (!elem) return;

    BSTR name = nullptr;
    if (SUCCEEDED(elem->get_CurrentName(&name)) && name) {
        std::wstring s(name);
        SysFreeString(name);
        if (s.size() > 4) out.push_back(s);
    }

    // 자식 요소 순회
    IUIAutomationTreeWalker* walker = nullptr;
    if (!pAuto_) return;
    pAuto_->get_RawViewWalker(&walker);
    if (!walker) return;

    IUIAutomationElement* child = nullptr;
    walker->GetFirstChildElement(elem, &child);
    while (child) {
        CollectTexts(child, out);
        IUIAutomationElement* next = nullptr;
        walker->GetNextSiblingElement(child, &next);
        child->Release();
        child = next;
    }
    walker->Release();
}

std::unordered_set<std::wstring> ForgeAutomation::CaptureSnapshot() {
    HWND kakaoHwnd = FindKakaoWindow();
    if (!kakaoHwnd) return {};
    IUIAutomationElement* root = GetUIElement(kakaoHwnd);
    if (!root) return {};
    std::vector<std::wstring> texts;
    CollectTexts(root, texts);
    root->Release();
    return std::unordered_set<std::wstring>(texts.begin(), texts.end());
}

// ── Utilities ────────────────────────────────────────────────────────────────

void ForgeAutomation::PostStatusToMain(const std::string& text,
                                        const std::string& color) {
    auto* s = new ForgeStatus{text, color, currentLevel, currentGold};
    PostMessage(mainHwnd_, WM_FORGE_STATUS, 0, (LPARAM)s);
}

void ForgeAutomation::SleepInterruptible(int ms) {
    for (int i = 0; i < ms / 50 && !shouldStop_.load(); i++) Sleep(50);
}

std::string ForgeAutomation::WstrToUtf8(const std::wstring& wstr) {
    if (wstr.empty()) return {};
    int sz = WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(),
                                  nullptr, 0, nullptr, nullptr);
    std::string s(sz, 0);
    WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(),
                         s.data(), sz, nullptr, nullptr);
    return s;
}
