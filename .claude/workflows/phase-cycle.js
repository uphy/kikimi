export const meta = {
  name: 'kikimi-phase-cycle',
  description: 'Kikimi の1機能を設計→レビュー→実装→単体テストまで一括で回す（UI 動作確認はユーザーに委譲。kikimi.md 17.6準拠）',
  phases: [
    { title: 'Design' },
    { title: 'Design Review' },
    { title: 'Design Revision' },
    { title: 'Implement' },
    { title: 'Unit Test' },
    { title: 'Final Review' },
  ],
}

// args: { feature: 'audio-capture', design_doc: 'docs/design/01-audio-capture.md' }
// UI verification is intentionally NOT part of this cycle: the user performs it manually
// after the cycle completes (see CLAUDE.local.md). Run kikimi-ui-verify only when asked.
// model 方針: 実装・テストの機械的工程は sonnet 固定。
// 設計起草・設計レビュー・モジュール分割・最終レビュー（判断が重い工程）はセッションモデルを継承する。

const REPO = '.'
const SPEC = 'kikimi.md'

const DESIGN_SCHEMA = {
  type: 'object',
  properties: {
    design_doc_path: { type: 'string', description: 'リポジトリルートからの相対パス' },
    summary: { type: 'string' },
    open_questions: { type: 'array', items: { type: 'string' } },
    deviations_from_kikimi_md: { type: 'array', items: { type: 'string' } },
  },
  required: ['design_doc_path', 'summary'],
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

const MODULE_LIST_SCHEMA = {
  type: 'object',
  properties: {
    modules: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          spec: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
        },
        required: ['name', 'spec'],
      },
    },
  },
  required: ['modules'],
}

const TEST_RESULT_SCHEMA = {
  type: 'object',
  properties: {
    passed: { type: 'boolean' },
    failures: { type: 'array', items: { type: 'string' } },
  },
  required: ['passed'],
}

const FINAL_REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['pass', 'pass_with_notes', 'fail'] },
    findings: { type: 'array', items: { type: 'string' } },
  },
  required: ['verdict', 'findings'],
}

// args must be an object: { feature, design_doc?, brief? }. A plain-string args once
// produced design_doc = "docs/design/undefined.md" and agents guessed a wrong target
// (wf_449c600e) — fail fast instead.
if (typeof args !== 'object' || args === null || typeof args.feature !== 'string' || args.feature.length === 0) {
  throw new Error('kikimi-phase-cycle requires object args: { feature: string, design_doc?: string, brief?: string }')
}
const feature = args.feature
const designDoc = args.design_doc || `docs/design/${feature}.md`
const designDocAbs = `${REPO}/${designDoc}`
// Optional pre-agreed design direction (e.g. from a grilling session with the user).
// Injected into the Design prompt so the draft starts from the agreement, not from scratch.
const brief = args.brief
  ? `\n\n## 合意済み設計方針（ユーザーと確定済み。逸脱する場合は設計文書に理由を明記すること）\n${args.brief}`
  : ''

function ctx() {
  return (
    `作業ディレクトリは ${REPO} （Kikimi リポジトリ）。仕様の単一真実は ${SPEC}（読み込み専用、変更しない）。` +
    `Kikimi 固有の運用ルールは ${REPO}/CLAUDE.md と ${REPO}/CLAUDE.local.md に書かれているので必ず読むこと。` +
    `Chirami 参照実装のマップは ${REPO}/docs/references/chirami-map.md にある。` +
    `Chirami（ローカル参照リポジトリ。場所は CLAUDE.local.md 参照）のコードは read-only 参照専用。絶対に変更しない。` +
    `コード・コメント・コミットメッセージは英語、会話向けの報告は日本語で書くこと。`
  )
}

phase('Design')
log(`Phase開始: feature=${feature}, design_doc=${designDoc}`)
const design = await agent(
  `${ctx()}\n\n機能「${feature}」の詳細設計ドキュメントを ${designDocAbs} に起草せよ。` +
    `kikimi.md の該当章を読み、API・型・状態遷移・失敗モードを具体的に書くこと。` +
    `Chirami の参照実装（chirami-map.md 参照）との差分がある場合は明記すること。` +
    `書き終えたら、書いたファイルパス（リポジトリルートからの相対パス）・要約・オープンな質問・` +
    `kikimi.md から逸脱した判断があれば列挙して返せ。${brief}`,
  { schema: DESIGN_SCHEMA, label: `design:${feature}` }
)

phase('Design Review')
const reviews = await parallel([
  () =>
    agent(
      `${ctx()}\n\n${REPO}/${design.design_doc_path} を読み、SWE（Software Engineer）視点で技術的妥当性・` +
        `見落としをレビューせよ。実装可能性・パフォーマンス・保守性の観点を重視。`,
      { agentType: 'swe', schema: REVIEW_SCHEMA, label: 'review:swe' }
    ),
  () =>
    agent(
      `${ctx()}\n\n${REPO}/${design.design_doc_path} を code-review skill 相当の観点（正確性・再利用性・` +
        `簡潔性・効率性）でレビューせよ。API 設計の一貫性・エラーハンドリング・テスト容易性を重視。`,
      { schema: REVIEW_SCHEMA, label: 'review:code-quality' }
    ),
  () =>
    agent(
      `${ctx()}\n\n${REPO}/${design.design_doc_path} と ${SPEC} を照らし合わせ、実装可能性チェックを行え。` +
        `Chirami の参照実装で実際にはカバーされていない・追加実装が必要な箇所を具体的に指摘せよ。`,
      { schema: REVIEW_SCHEMA, label: 'review:feasibility' }
    ),
])

const blockers = reviews.filter(Boolean).flatMap((r) => r.blockers || [])
let finalDesign = design
if (blockers.length > 0) {
  phase('Design Revision')
  log(`設計レビューで ${blockers.length} 件のブロッカーを検出。設計を1回だけ修正する。`)
  finalDesign = await agent(
    `${ctx()}\n\n${REPO}/${design.design_doc_path} に対して以下のレビュー指摘を反映し、設計を更新せよ:\n` +
      blockers.map((b) => `- ${b}`).join('\n'),
    { schema: DESIGN_SCHEMA, label: `design-revise:${feature}` }
  )
} else {
  log('設計レビューにブロッカーなし。実装工程へ進む。')
}

phase('Implement')
const moduleList = await agent(
  `${ctx()}\n\n${REPO}/${finalDesign.design_doc_path} を読み、実装すべきモジュール（Swift ファイル単位程度の` +
    `粒度）をリストアップせよ。各モジュールに name・実装すべき内容の spec・関連ファイルパスを含めること。`,
  { schema: MODULE_LIST_SCHEMA, label: `modules:${feature}` }
)
log(`実装対象モジュール数: ${moduleList.modules.length}`)

// 実装とセルフレビューはモジュール単位で独立なので pipeline で並列に進める。ただし単体テストは
// 意図的に pipeline に含めず、全モジュール完了後に統合実行の agent を1回だけ呼ぶ（下記）。理由:
// このリポジトリは単一の Swift Package（.build を共有）なので、モジュールごとに並列で
// `swift build`/`swift test` を走らせると .build のロック競合で複数 agent が同時に長時間ブロックし、
// stall 判定（無進捗タイムアウト）で Workflow 全体が失敗する（audio-capture フェーズで実際に発生した
// 障害。judgment log 参照）。
const implementations = await pipeline(
  moduleList.modules,
  (m) =>
    agent(
      `${ctx()}\n\n設計ドキュメント ${REPO}/${finalDesign.design_doc_path} に基づき、モジュール「${m.name}」を` +
        `実装せよ。\n仕様:\n${m.spec}\n関連ファイル: ${(m.files || []).join(', ')}\n` +
        `実装のみ行い、\`swift build\`/\`swift test\` は実行しないこと（統合ビルド・テストは後続の専用工程で` +
        `1回だけ行う）。実装後、変更したファイル一覧を報告せよ。`,
      { label: `impl:${m.name}`, model: 'sonnet' }
    ),
  (impl, m) =>
    agent(
      `${ctx()}\n\n直前に実装されたモジュール「${m.name}」（実装報告: ${String(impl).slice(0, 2000)}）を` +
        `コードリーディングでセルフレビューせよ（\`swift build\`/\`swift test\` は実行しないこと）。` +
        `バグ・仕様との齟齬・簡略化できる箇所を指摘し、軽微なものはその場で修正せよ。`,
      { label: `selfreview:${m.name}`, model: 'sonnet' }
    )
)

phase('Unit Test')
log('全モジュールの実装完了。統合ビルド・単体テストを1回だけ実行する。')
const testResult = await agent(
  `${ctx()}\n\n実装済みの全モジュール（${moduleList.modules.map((m) => m.name).join(', ')}）に対して、` +
    `${REPO}/KikimiTests/ に不足している単体テスト（swift-testing）を追加し、\`swift build\` →` +
    `\`swift test\` を実行して結果を報告せよ。\n` +
    `**重要**: このリポジトリは単一の Swift Package（.build を共有）なので、\`swift build\`/\`swift test\` を` +
    `並列・多重実行しないこと（他プロセスとロック競合してハングする）。1回のコマンドの完了を必ず待ってから次を` +
    `実行すること。長時間（sherpa-onnx の初回ビルド等）かかる場合があるので、コマンドはバックグラウンド実行や` +
    `十分なタイムアウトで扱うこと。\n` +
    `失敗した場合は原因を修正して再実行し、最終結果（passed/failures）を返せ。`,
  { schema: TEST_RESULT_SCHEMA, label: `test:${feature}`, model: 'sonnet' }
)

if (testResult.passed === false) {
  log('単体テスト失敗。1回だけ修正して再実行する。')
  const retryTest = await agent(
    `${ctx()}\n\n機能「${feature}」の単体テストが失敗した:\n${(testResult.failures || []).join('\n')}\n` +
      `原因を調査して実装またはテストを修正し、\`swift build\` → \`swift test\` を再実行して通ることを` +
      `確認せよ（多重実行しないこと）。最終結果を返せ。`,
    { schema: TEST_RESULT_SCHEMA, label: `test-retry:${feature}`, model: 'sonnet' }
  )
  Object.assign(testResult, retryTest)
} else {
  log('全モジュールの単体テストが通過。')
}

phase('Final Review')
const finalReview = await agent(
  `${ctx()}\n\n機能「${feature}」の全実装差分（git diff）に対して code-review skill 相当の観点で最終レビューを` +
    `実施せよ。バグ・セキュリティ・kikimi.md からの逸脱・簡略化できる箇所を報告せよ。`,
  { schema: FINAL_REVIEW_SCHEMA, label: `final-review:${feature}` }
)

log(`Phase完了: feature=${feature}, final verdict=${finalReview.verdict}。UI 動作確認はユーザーに委譲する。`)

return {
  feature,
  design: finalDesign,
  reviews,
  moduleList,
  implementations,
  finalReview,
  uiVerification: 'not-run: performed manually by the user (run kikimi-ui-verify only on request)',
}
