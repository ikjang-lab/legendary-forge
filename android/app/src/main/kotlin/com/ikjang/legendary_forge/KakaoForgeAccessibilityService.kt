package com.ikjang.legendary_forge

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.*
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.*
import java.util.regex.Pattern

class KakaoForgeAccessibilityService : AccessibilityService() {

    companion object {
        const val PREF_NAME = "forge_prefs"
        const val PREF_TARGET_LEVEL = "target_level"
        const val KAKAO_PACKAGE = "com.kakao.talk"
        const val TAG = "ForgeService"
        var instance: KakaoForgeAccessibilityService? = null
    }

    private var windowManager: WindowManager? = null
    private var overlayRoot: View? = null
    private val handler = Handler(Looper.getMainLooper())

    // State
    private var isRunning = false
    private var targetLevel = 10
    private var currentLevel = 0
    private var currentGold = 0L
    private var waitingForResponse = false
    // 명령 전송 직전에 찍은 화면 텍스트 스냅샷. 이 안에 있는 텍스트는 이미 존재한 것이므로 스킵.
    private var preCommandSnapshot = emptySet<String>()
    // 현재 대기 사이클에서 이미 처리한 텍스트(동일 이벤트 중복 방지용)
    private var processedInCycle = LinkedHashSet<String>()
    // Buffer that accumulates NEW text nodes while waiting for a bot response.
    private val pendingBotTexts = mutableListOf<String>()

    // Overlay views
    private var tvCurrentLevel: TextView? = null
    private var tvTargetLevel: TextView? = null
    private var tvGold: TextView? = null
    private var tvStatus: TextView? = null
    private var btnStartStop: Button? = null

    private val prefs: SharedPreferences by lazy {
        getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
    }

    private val doSendRunnable = Runnable { trySendCommand() }
    private val timeoutRunnable = Runnable {
        if (isRunning && waitingForResponse) {
            waitingForResponse = false
            setStatus("응답 없음 - 재시도", Color.parseColor("#FFAA00"))
            handler.postDelayed(doSendRunnable, 1500)
        }
    }
    private val scanRunnable = Runnable { scanForBotResponse() }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        targetLevel = prefs.getInt(PREF_TARGET_LEVEL, 10)
        handler.post { showOverlay() }
    }

    override fun onDestroy() {
        super.onDestroy()
        instance = null
        isRunning = false
        handler.removeCallbacksAndMessages(null)
        removeOverlay()
    }

    override fun onInterrupt() {
        isRunning = false
    }

    // ── Accessibility Events ──────────────────────────────────────────────────

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (event.packageName?.toString() != KAKAO_PACKAGE) return
        if (!isRunning || !waitingForResponse) return

        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED -> {
                // 디바운스: UI가 완전히 렌더링될 시간을 주고 스캔
                handler.removeCallbacks(scanRunnable)
                handler.postDelayed(scanRunnable, 300)
            }
        }
    }

    // ── Command Sending ───────────────────────────────────────────────────────

    private fun captureTextSnapshot(): Set<String> {
        val root = rootInActiveWindow ?: return emptySet()
        if (root.packageName?.toString() != KAKAO_PACKAGE) return emptySet()
        val texts = mutableListOf<String>()
        collectTexts(root, texts)
        return texts.toHashSet()
    }

    private fun trySendCommand() {
        if (!isRunning) return

        // 명령 전송 전에 현재 화면을 스냅샷으로 저장 → 이후 스캔에서 새 메시지만 감지
        preCommandSnapshot = captureTextSnapshot()
        processedInCycle.clear()
        pendingBotTexts.clear()

        val root = rootInActiveWindow
        if (root == null) {
            setStatus("화면 정보 없음 - 카카오톡 확인", Color.parseColor("#FF6666"))
            handler.postDelayed(doSendRunnable, 2000)
            return
        }

        val pkg = root.packageName?.toString() ?: ""
        if (pkg != KAKAO_PACKAGE) {
            setStatus("카카오톡 채팅방으로 이동하세요", Color.parseColor("#FF6666"))
            handler.postDelayed(doSendRunnable, 2000)
            return
        }

        val inputNode = findInputField(root)
        if (inputNode == null) {
            Log.w(TAG, "Input not found. Tree:\n${buildDebugInfo(root)}")
            setStatus("입력창 탐색 재시도...", Color.parseColor("#FFAA00"))
            handler.postDelayed(doSendRunnable, 1500)
            return
        }

        // Focus the input field
        inputNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)

        handler.postDelayed({
            // Set text "/강화"
            val args = Bundle()
            args.putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "/강화"
            )
            val setOk = inputNode.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
            Log.d(TAG, "SET_TEXT result: $setOk, id: ${inputNode.viewIdResourceName}")

            handler.postDelayed({
                val root2 = rootInActiveWindow ?: return@postDelayed
                val freshInput = findInputField(root2) ?: inputNode
                val sendBtn = findSendButton(root2, freshInput)

                if (sendBtn != null) {
                    Log.d(TAG, "Send btn found: ${sendBtn.viewIdResourceName} desc:${sendBtn.contentDescription}")
                    val clickOk = sendBtn.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    Log.d(TAG, "CLICK result: $clickOk")
                    if (clickOk) {
                        waitingForResponse = true
                        setStatus("💬 응답 대기...", Color.parseColor("#AAAAFF"))
                        handler.postDelayed(timeoutRunnable, 7000)
                    } else {
                        setStatus("전송 실패 - 재시도", Color.parseColor("#FFAA00"))
                        handler.postDelayed(doSendRunnable, 1500)
                    }
                } else {
                    // Fallback: IME action (Enter key)
                    @Suppress("DEPRECATION")
                    val imeOk = freshInput.performAction(0x01000008)
                    Log.d(TAG, "IME_ENTER result: $imeOk")
                    if (imeOk) {
                        waitingForResponse = true
                        setStatus("💬 응답 대기...", Color.parseColor("#AAAAFF"))
                        handler.postDelayed(timeoutRunnable, 7000)
                    } else {
                        setStatus("전송버튼 없음 - 재시도", Color.parseColor("#FFAA00"))
                        handler.postDelayed(doSendRunnable, 1500)
                    }
                }
            }, 300)
        }, 150)
    }

    // ── Bot Response Parsing ──────────────────────────────────────────────────

    private fun scanForBotResponse() {
        val root = rootInActiveWindow ?: return
        if (root.packageName?.toString() != KAKAO_PACKAGE) return

        val texts = mutableListOf<String>()
        collectTexts(root, texts)

        var foundGold = false
        for (text in texts) {
            // 명령 전송 전에 이미 있던 텍스트는 스킵 (유지→유지 중복 방지 핵심 로직)
            if (text in preCommandSnapshot) continue
            // 이번 대기 사이클에서 이미 처리한 텍스트도 스킵 (중복 이벤트 방지)
            if (!processedInCycle.add(text)) continue

            pendingBotTexts.add(text)
            if (text.contains("남은 골드") || text.contains("보유 골드")) foundGold = true
        }

        if (foundGold) {
            val combined = pendingBotTexts.joinToString("\n")
            pendingBotTexts.clear()
            handleBotMessage(combined)
        }
    }

    private fun handleBotMessage(text: String) {
        handler.removeCallbacks(timeoutRunnable)
        waitingForResponse = false

        val resultType = when {
            text.contains("강화 성공") -> "success"
            text.contains("강화 파괴") -> "destroy"
            else -> "maintain"
        }

        val levelPattern = Pattern.compile("→ \\+([0-9]+)")
        val levelMatcher = levelPattern.matcher(text)
        val goldPattern = Pattern.compile("(?:남은|보유) 골드: ([0-9,]+)G")
        val goldMatcher = goldPattern.matcher(text)

        if (goldMatcher.find()) {
            currentGold = goldMatcher.group(1)?.replace(",", "")?.toLongOrNull() ?: currentGold
        }

        when (resultType) {
            "success" -> {
                if (levelMatcher.find()) {
                    currentLevel = levelMatcher.group(1)?.toIntOrNull() ?: (currentLevel + 1)
                } else {
                    currentLevel++
                }
            }
            "destroy" -> currentLevel = 0
        }

        val (statusText, statusColor) = when (resultType) {
            "success" -> "✨ 성공! → +$currentLevel" to Color.parseColor("#00FF88")
            "destroy" -> "💥 파괴... +0으로 리셋" to Color.parseColor("#FF4444")
            else -> "💦 유지 +$currentLevel" to Color.parseColor("#4488FF")
        }

        handler.post {
            tvCurrentLevel?.text = "현재: +$currentLevel"
            tvGold?.text = "골드: ${fmtGold(currentGold)}G"
            setStatus(statusText, statusColor)
        }

        if (!isRunning) return

        if (currentLevel >= targetLevel) {
            handler.post {
                stop()
                setStatus("🎉 +$targetLevel 달성!", Color.parseColor("#FFD700"))
            }
            return
        }

        handler.postDelayed(doSendRunnable, 800)
    }

    // ── Node Finders ──────────────────────────────────────────────────────────

    /**
     * Try multiple strategies to find the chat input field.
     */
    private fun findInputField(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        // Strategy 1: known resource IDs
        val ids = listOf(
            "com.kakao.talk:id/message_text",
            "com.kakao.talk:id/chat_input_edit_text",
            "com.kakao.talk:id/emoticon_text_input",
            "com.kakao.talk:id/input_text",
            "com.kakao.talk:id/et_content",
            "com.kakao.talk:id/et_message",
            "com.kakao.talk:id/edittext_chat_input",
            "com.kakao.talk:id/chat_text_input",
            "com.kakao.talk:id/input_edit_text",
            "com.kakao.talk:id/textInput",
            "com.kakao.talk:id/text_input",
        )
        for (id in ids) {
            root.findAccessibilityNodeInfosByViewId(id)
                .firstOrNull()
                ?.let { return it }
        }

        // Strategy 2: any node that is editable (no class name restriction)
        findByEditable(root)?.let { return it }

        // Strategy 3: any EditText-class node that is enabled
        findByClassName(root, "EditText")?.let { return it }
        findByClassName(root, "android.widget.EditText")?.let { return it }

        return null
    }

    /** Depth-first search for any node where isEditable = true */
    private fun findByEditable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val r = findByEditable(child)
            if (r != null) return r
        }
        return null
    }

    /** Depth-first search for any node whose className contains [name] */
    private fun findByClassName(node: AccessibilityNodeInfo, name: String): AccessibilityNodeInfo? {
        if (node.className?.toString()?.contains(name) == true && node.isEnabled) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val r = findByClassName(child, name)
            if (r != null) return r
        }
        return null
    }

    /**
     * Find the send button using multiple strategies, in priority order:
     * 1. Known resource IDs
     * 2. Content-description exactly matches "전송"/"send"
     * 3. Sibling nodes that come AFTER the input field in its parent
     *    (send button is to the right; attachment button is to the left)
     */
    private fun findSendButton(
        root: AccessibilityNodeInfo,
        inputNode: AccessibilityNodeInfo? = null
    ): AccessibilityNodeInfo? {
        // Strategy 1: known resource IDs
        val ids = listOf(
            "com.kakao.talk:id/send_button",
            "com.kakao.talk:id/btn_send",
            "com.kakao.talk:id/chat_send",
            "com.kakao.talk:id/iv_send",
            "com.kakao.talk:id/sendButton",
            "com.kakao.talk:id/button_send",
            "com.kakao.talk:id/btnSend",
        )
        for (id in ids) {
            root.findAccessibilityNodeInfosByViewId(id)
                .firstOrNull()
                ?.let { return it }
        }

        // Strategy 2: content description / text exactly "전송" or "보내기"
        findByExactSendDesc(root)?.let { return it }

        // Strategy 3: siblings AFTER the input field in parent container
        // (the send button is to the RIGHT of the input, attachment is to the LEFT)
        if (inputNode != null) {
            findSendSiblingAfterInput(inputNode)?.let { return it }
        }

        return null
    }

    /** Only matches exact "전송" or "보내기" to avoid false positives */
    private fun findByExactSendDesc(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (node.isClickable) {
            val desc = node.contentDescription?.toString() ?: ""
            val text = node.text?.toString() ?: ""
            if (desc == "전송" || desc == "보내기" || desc == "send" ||
                text == "전송" || text == "보내기") {
                return node
            }
        }
        for (i in 0 until node.childCount) {
            val r = findByExactSendDesc(node.getChild(i) ?: continue)
            if (r != null) return r
        }
        return null
    }

    /**
     * Walk up to the input's parent row, then collect clickable siblings
     * that appear AFTER the input node index. Return the last one (rightmost).
     * KakaoTalk layout: [sticker][+attach] [  input  ] [send]
     */
    private fun findSendSiblingAfterInput(inputNode: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        val parent = inputNode.parent ?: return null
        var inputIndex = -1
        for (i in 0 until parent.childCount) {
            if (parent.getChild(i)?.viewIdResourceName == inputNode.viewIdResourceName &&
                parent.getChild(i)?.isEditable == true) {
                inputIndex = i
                break
            }
        }
        if (inputIndex < 0) return null

        // Collect all clickable nodes from siblings AFTER the input
        val candidates = mutableListOf<AccessibilityNodeInfo>()
        for (i in (inputIndex + 1) until parent.childCount) {
            val sibling = parent.getChild(i) ?: continue
            collectClickable(sibling, candidates)
        }
        Log.d(TAG, "Send candidates after input (idx=$inputIndex): ${candidates.map { it.viewIdResourceName ?: it.contentDescription }}")
        // Return the first one right after input (send button is immediately next)
        return candidates.firstOrNull()
    }

    private fun collectClickable(node: AccessibilityNodeInfo, out: MutableList<AccessibilityNodeInfo>) {
        if (node.isClickable) out.add(node)
        for (i in 0 until node.childCount) collectClickable(node.getChild(i) ?: continue, out)
    }

    private fun collectTexts(node: AccessibilityNodeInfo, out: MutableList<String>) {
        val t = node.text?.toString()
        val desc = node.contentDescription?.toString()
        // text 우선, 없으면 contentDescription 확인
        val content = when {
            !t.isNullOrBlank() -> t
            !desc.isNullOrBlank() -> desc
            else -> null
        }
        if (content != null && content.length > 4) out.add(content)
        for (i in 0 until node.childCount) {
            collectTexts(node.getChild(i) ?: continue, out)
        }
    }

    /**
     * Build a compact dump of editable/clickable nodes for debugging.
     */
    private fun buildDebugInfo(root: AccessibilityNodeInfo): String {
        val sb = StringBuilder()
        fun walk(node: AccessibilityNodeInfo, depth: Int) {
            val indent = "  ".repeat(depth)
            val cls = node.className?.toString()?.substringAfterLast('.') ?: "?"
            val id = node.viewIdResourceName ?: ""
            val editable = if (node.isEditable) " [EDIT]" else ""
            val clickable = if (node.isClickable) " [CLICK]" else ""
            val text = node.text?.toString()?.take(20)?.let { " \"$it\"" } ?: ""
            val desc = node.contentDescription?.toString()?.take(20)?.let { " desc:$it" } ?: ""
            if (editable.isNotEmpty() || id.isNotEmpty()) {
                sb.appendLine("$indent$cls$editable$clickable id=$id$text$desc")
            }
            for (i in 0 until node.childCount) {
                walk(node.getChild(i) ?: continue, depth + 1)
            }
        }
        walk(root, 0)
        return sb.toString()
    }

    // ── Start / Stop ──────────────────────────────────────────────────────────

    private fun toggleStartStop() {
        if (isRunning) stop() else start()
    }

    private fun start() {
        if (currentLevel >= targetLevel) {
            setStatus("이미 목표 달성!", Color.parseColor("#FFD700"))
            return
        }
        isRunning = true
        waitingForResponse = false
        handler.post {
            btnStartStop?.text = "⏹  중지"
            btnStartStop?.setBackgroundColor(Color.parseColor("#8B0000"))
        }
        setStatus("강화 시작...", Color.parseColor("#00FF88"))
        handler.postDelayed(doSendRunnable, 600)
    }

    private fun stop() {
        isRunning = false
        waitingForResponse = false
        pendingBotTexts.clear()
        processedInCycle.clear()
        preCommandSnapshot = emptySet()
        handler.removeCallbacks(doSendRunnable)
        handler.removeCallbacks(timeoutRunnable)
        handler.removeCallbacks(scanRunnable)
        handler.post {
            btnStartStop?.text = "🔨 시작"
            btnStartStop?.setBackgroundColor(Color.parseColor("#B8860B"))
        }
        setStatus("중지됨", Color.parseColor("#AAAAAA"))
    }

    private fun setStatus(text: String, color: Int) {
        handler.post {
            tvStatus?.text = text
            tvStatus?.setTextColor(color)
        }
    }

    // ── Overlay Build ─────────────────────────────────────────────────────────

    private fun showOverlay() {
        if (overlayRoot != null) return
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = 16
            y = 220
        }

        val view = buildOverlayView()
        overlayRoot = view
        windowManager?.addView(view, params)
        setupDrag(view, params)
    }

    private fun buildOverlayView(): View {
        val dp = resources.displayMetrics.density
        fun dp(v: Int) = (v * dp).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#E61A1A2E"))
            setPadding(dp(12), dp(10), dp(12), dp(12))
            elevation = 12f
        }

        // Title row (title + close button)
        val titleRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        titleRow.addView(TextView(this).apply {
            text = "⚔️ 자동강화"
            setTextColor(Color.parseColor("#FFD700"))
            textSize = 13f
            typeface = Typeface.DEFAULT_BOLD
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        })
        titleRow.addView(Button(this).apply {
            text = "✕"
            textSize = 12f
            setTextColor(Color.parseColor("#AAAAAA"))
            setBackgroundColor(Color.TRANSPARENT)
            layoutParams = LinearLayout.LayoutParams(dp(32), dp(28))
            setPadding(0, 0, 0, 0)
            setOnClickListener {
                stop()
                removeOverlay()
                disableSelf()
            }
        })
        root.addView(titleRow)
        root.addView(divider(dp(1)))

        // Current level
        tvCurrentLevel = TextView(this).apply {
            text = "현재: +$currentLevel"
            setTextColor(Color.WHITE)
            textSize = 12f
            setPadding(0, dp(4), 0, 0)
        }
        root.addView(tvCurrentLevel)

        // Gold
        tvGold = TextView(this).apply {
            text = "골드: -"
            setTextColor(Color.parseColor("#FFD700"))
            textSize = 11f
            setPadding(0, dp(2), 0, dp(4))
        }
        root.addView(tvGold)

        // Target level row
        val targetRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        targetRow.addView(TextView(this).apply {
            text = "목표: "
            setTextColor(Color.WHITE)
            textSize = 12f
        })
        val btnMinus = makeSmallBtn("-") {
            if (!isRunning && targetLevel > 1) {
                targetLevel--
                tvTargetLevel?.text = "+$targetLevel"
                prefs.edit().putInt(PREF_TARGET_LEVEL, targetLevel).apply()
            }
        }
        tvTargetLevel = TextView(this).apply {
            text = "+$targetLevel"
            setTextColor(Color.parseColor("#FFD700"))
            textSize = 14f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            layoutParams = LinearLayout.LayoutParams(dp(46), LinearLayout.LayoutParams.WRAP_CONTENT)
        }
        val btnPlus = makeSmallBtn("+") {
            if (!isRunning && targetLevel < 20) {
                targetLevel++
                tvTargetLevel?.text = "+$targetLevel"
                prefs.edit().putInt(PREF_TARGET_LEVEL, targetLevel).apply()
            }
        }
        targetRow.addView(btnMinus)
        targetRow.addView(tvTargetLevel)
        targetRow.addView(btnPlus)
        root.addView(targetRow)

        root.addView(divider(dp(1)))

        // Status
        tvStatus = TextView(this).apply {
            text = "대기 중"
            setTextColor(Color.parseColor("#AAAAAA"))
            textSize = 10f
            setPadding(0, dp(4), 0, 0)
        }
        root.addView(tvStatus)

        // Start/Stop button
        btnStartStop = Button(this).apply {
            text = "🔨 시작"
            textSize = 12f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#B8860B"))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(8) }
            setPadding(0, dp(4), 0, dp(4))
            setOnClickListener { toggleStartStop() }
        }
        root.addView(btnStartStop)

        // Debug button: dumps node info to logcat + status
        val btnDebug = Button(this).apply {
            text = "🔍 진단"
            textSize = 10f
            setTextColor(Color.parseColor("#AAAAAA"))
            setBackgroundColor(Color.parseColor("#22FFFFFF"))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = dp(4) }
            setPadding(0, dp(2), 0, dp(2))
            setOnClickListener { runDiagnosis() }
        }
        root.addView(btnDebug)

        return root
    }

    /**
     * Diagnostic: finds all editable nodes in the current window and logs them.
     * Updates status with a short summary.
     */
    private fun runDiagnosis() {
        val root = rootInActiveWindow
        if (root == null) {
            setStatus("진단: 화면 없음", Color.parseColor("#FF6666"))
            return
        }
        val pkg = root.packageName?.toString() ?: "?"
        Log.d(TAG, "=== DIAGNOSIS: pkg=$pkg ===")
        val info = buildDebugInfo(root)
        Log.d(TAG, info)

        // Collect all IDs for a quick toast
        val editNodes = mutableListOf<String>()
        fun walk(n: AccessibilityNodeInfo) {
            if (n.isEditable || n.className?.contains("EditText") == true) {
                editNodes.add(n.viewIdResourceName ?: n.className?.toString() ?: "?")
            }
            for (i in 0 until n.childCount) walk(n.getChild(i) ?: return)
        }
        walk(root)

        val summary = if (editNodes.isEmpty()) "EditText 없음 (pkg=$pkg)"
                      else "Found: ${editNodes.joinToString()}"
        setStatus("진단: $summary", Color.parseColor("#FFFF88"))
        Log.d(TAG, "EditNodes: $editNodes")
    }

    private fun makeSmallBtn(label: String, onClick: () -> Unit): Button {
        val dp = resources.displayMetrics.density
        return Button(this).apply {
            text = label
            textSize = 14f
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.parseColor("#44FFFFFF"))
            layoutParams = LinearLayout.LayoutParams((30 * dp).toInt(), (30 * dp).toInt())
            setPadding(0, 0, 0, 0)
            setOnClickListener { onClick() }
        }
    }

    private fun divider(heightPx: Int): View {
        val dp = resources.displayMetrics.density
        return View(this).apply {
            setBackgroundColor(Color.parseColor("#44FFFFFF"))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, heightPx
            ).apply { setMargins(0, (5 * dp).toInt(), 0, (5 * dp).toInt()) }
        }
    }

    private fun setupDrag(view: View, params: WindowManager.LayoutParams) {
        var ix = 0; var iy = 0; var tx = 0f; var ty = 0f; var moved = false
        view.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    ix = params.x; iy = params.y
                    tx = event.rawX; ty = event.rawY
                    moved = false; false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - tx).toInt()
                    val dy = (event.rawY - ty).toInt()
                    if (!moved && (kotlin.math.abs(dx) > 8 || kotlin.math.abs(dy) > 8)) moved = true
                    if (moved) {
                        params.x = ix - dx
                        params.y = iy + dy
                        windowManager?.updateViewLayout(view, params)
                    }
                    moved
                }
                else -> false
            }
        }
    }

    private fun removeOverlay() {
        overlayRoot?.let {
            try { windowManager?.removeView(it) } catch (_: Exception) {}
            overlayRoot = null
        }
    }

    private fun fmtGold(g: Long): String {
        if (g >= 1_000_000L) return "%.1fM".format(g / 1_000_000.0)
        return "%,d".format(g)
    }
}
