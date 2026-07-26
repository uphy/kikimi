export const meta = {
  name: 'kikimi-fix-cycle',
  description: 'バグ修正・小改修を1機能未満の粒度で回す軽量サイクル: 調査/実装→レビュー→ビルド/テスト（UI 動作確認はユーザーに委譲。kikimi.md 17.6準拠）',
  phases: [
    { title: 'Investigate & Implement' },
    { title: 'Review' },
    { title: 'Apply Review Fixes' },
    { title: 'Build & Test' },
  ],
}

// args: { task: 'サマリペインの更新ドットが一時停止後に消えないバグを直す' }
// UI verification is intentionally NOT part of this cycle: the user performs it manually
// after the cycle completes (see CLAUDE.local.md). Run kikimi-ui-verify only when asked.
// model 方針: 機械的な工程（調査/実装・ビルド/テスト）は sonnet 固定。
// 品質ゲートである Review だけはセッションモデルを継承する（上位モデルのセッションから起動すると自動で強くなる）。

const REPO = '.'
const SPEC = 'kikimi.md'

const IMPLEMENT_SCHEMA = {
  type: 'object',
  properties: {
    summary: { type: 'string' },
    changed_files: { type: 'array', items: { type: 'string' } },
  },
  required: ['summary'],
}

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['approve', 'approve_with_comments', 'request_changes'] },
    blockers: { type: 'array', items: { type: 'string' } },
    suggestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['verdict', 'blockers', 'suggestions'],
}

const TEST_RESULT_SCHEMA = {
  type: 'object',
  properties: {
    passed: { type: 'boolean' },
    failures: { type: 'array', items: { type: 'string' } },
  },
  required: ['passed'],
}

const task = args.task
if (!task) {
  throw new Error('args.task が必要です（バグや小改修の説明）')
}

function ctx() {
  return (
    `作業ディレクトリは ${REPO} （Kikimi リポジトリ）。仕様の単一真実は ${SPEC}（読み込み専用、変更しない）。` +
    `Kikimi 固有の運用ルールは ${REPO}/CLAUDE.md と ${REPO}/CLAUDE.local.md に書かれているので必ず読むこと。` +
    `Chirami 参照実装のマップは ${REPO}/docs/references/chirami-map.md にある。` +
    `Chirami（ローカル参照リポジトリ。場所は CLAUDE.local.md 参照）のコードは read-only 参照専用。絶対に変更しない。` +
    `コード・コメント・コミットメッセージは英語、会話向けの報告は日本語で書くこと。`
  )
}

phase('Investigate & Implement')
log(`fix-cycle 開始: ${task}`)
const implementation = await agent(
  `${ctx()}\n\n以下のタスクについて原因調査を行い、修正を実装せよ:\n${task}\n` +
    `1機能未満の小規模な修正・バグ修正を想定している。過剰な設計文書化はせず、必要ならコード内コメントで` +
    `意図を残すこと。修正後、変更したファイル一覧と要約を返せ。`,
  { schema: IMPLEMENT_SCHEMA, label: 'fix:implement', model: 'sonnet' }
)

phase('Review')
const review = await agent(
  `${ctx()}\n\n直前の修正（${implementation.summary}、変更ファイル: ` +
    `${(implementation.changed_files || []).join(', ')}）について、code-review skill 相当の観点` +
    `（正確性・再利用性・簡潔性・効率性）で git diff をレビューせよ。`,
  { schema: REVIEW_SCHEMA, label: 'fix:review' }
)

if (review.blockers && review.blockers.length > 0) {
  phase('Apply Review Fixes')
  log(`レビューで ${review.blockers.length} 件のブロッカーを検出。1回だけ修正する。`)
  await agent(
    `${ctx()}\n\n以下のレビュー指摘を反映して修正せよ:\n${review.blockers.map((b) => `- ${b}`).join('\n')}`,
    { schema: IMPLEMENT_SCHEMA, label: 'fix:apply-review', model: 'sonnet' }
  )
} else {
  log('レビューにブロッカーなし。')
}

phase('Build & Test')
let testResult = await agent(
  `${ctx()}\n\n\`mise run build\` を実行し、修正内容（${task}）に関連する単体テストを` +
    `（既存があれば実行し、追加が妥当なら ${REPO}/KikimiTests/ に追加してから）実行せよ。` +
    `最終結果（passed/failures）を返せ。`,
  { schema: TEST_RESULT_SCHEMA, label: 'fix:build-test', model: 'sonnet' }
)

if (testResult.passed === false) {
  log('ビルドまたはテスト失敗。1回だけ修正して再実行する。')
  testResult = await agent(
    `${ctx()}\n\n\`mise run build\` またはテストが失敗した:\n${(testResult.failures || []).join('\n')}\n` +
      `原因を修正し、\`mise run build\` →関連テストを再実行して通ることを確認せよ。最終結果を返せ。`,
    { schema: TEST_RESULT_SCHEMA, label: 'fix:build-test-retry', model: 'sonnet' }
  )
}

log(`fix-cycle 完了: task=${task}, testPassed=${testResult.passed}。UI 動作確認はユーザーに委譲する。`)

return {
  task,
  implementation,
  review,
  testResult,
  uiVerification: 'not-run: performed manually by the user (run kikimi-ui-verify only on request)',
}
