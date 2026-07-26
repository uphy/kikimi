export const meta = {
  name: 'kikimi-design-review',
  description: '設計文書を並列 subagent（swe視点/code-review視点/実装可能性チェック）でレビューし、blockerがあれば1回だけ修正する（kikimi.md 17.6準拠）',
  phases: [
    { title: 'Design Review' },
    { title: 'Design Revision' },
  ],
}

// args: { design_doc: 'docs/design/03-refinement-batch.md' }
// model 方針: 全工程が判断の重いレビュー・設計修正なので、意図的に model 指定なし
// （セッションモデルを継承。上位モデルのセッションから起動すると自動で強くなる）。

const REPO = '.'
const SPEC = 'kikimi.md'

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['approve', 'approve_with_comments', 'request_changes'] },
    blockers: { type: 'array', items: { type: 'string' } },
    suggestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['verdict', 'blockers', 'suggestions'],
}

const REVISION_SCHEMA = {
  type: 'object',
  properties: {
    design_doc_path: { type: 'string', description: 'リポジトリルートからの相対パス' },
    summary: { type: 'string' },
    changes: { type: 'array', items: { type: 'string' } },
  },
  required: ['design_doc_path', 'summary'],
}

const designDoc = args.design_doc
if (!designDoc) {
  throw new Error('args.design_doc が必要です（例: docs/design/03-refinement-batch.md）')
}
const designDocAbs = `${REPO}/${designDoc}`

function ctx() {
  return (
    `作業ディレクトリは ${REPO} （Kikimi リポジトリ）。仕様の単一真実は ${SPEC}（読み込み専用、変更しない）。` +
    `Kikimi 固有の運用ルールは ${REPO}/CLAUDE.md と ${REPO}/CLAUDE.local.md に書かれているので必ず読むこと。` +
    `Chirami 参照実装のマップは ${REPO}/docs/references/chirami-map.md にある。` +
    `Chirami（ローカル参照リポジトリ。場所は CLAUDE.local.md 参照）のコードは read-only 参照専用。絶対に変更しない。` +
    `コード・コメント・コミットメッセージは英語、会話向けの報告は日本語で書くこと。`
  )
}

phase('Design Review')
log(`設計文書をレビューする: ${designDoc}`)
const reviews = await parallel([
  () =>
    agent(
      `${ctx()}\n\n${designDocAbs} を読み、SWE（Software Engineer）視点で技術的妥当性・見落としをレビューせよ。` +
        `実装可能性・パフォーマンス・保守性の観点を重視。`,
      { agentType: 'swe', schema: REVIEW_SCHEMA, label: 'review:swe' }
    ),
  () =>
    agent(
      `${ctx()}\n\n${designDocAbs} を code-review skill 相当の観点（正確性・再利用性・簡潔性・効率性）で` +
        `レビューせよ。API 設計の一貫性・エラーハンドリング・テスト容易性を重視。`,
      { schema: REVIEW_SCHEMA, label: 'review:code-quality' }
    ),
  () =>
    agent(
      `${ctx()}\n\n${designDocAbs} と ${SPEC} を照らし合わせ、実装可能性チェックを行え。Chirami の参照実装で` +
        `実際にはカバーされていない・追加実装が必要な箇所を具体的に指摘せよ。`,
      { schema: REVIEW_SCHEMA, label: 'review:feasibility' }
    ),
])

const blockers = reviews.filter(Boolean).flatMap((r) => r.blockers || [])
const suggestions = reviews.filter(Boolean).flatMap((r) => r.suggestions || [])

let revision = null
if (blockers.length > 0) {
  phase('Design Revision')
  log(`設計レビューで ${blockers.length} 件のブロッカーを検出。設計を1回だけ修正する。`)
  revision = await agent(
    `${ctx()}\n\n${designDocAbs} に対して以下のレビュー指摘を反映し、設計文書を更新せよ:\n` +
      blockers.map((b) => `- ${b}`).join('\n'),
    { schema: REVISION_SCHEMA, label: 'design-revise' }
  )
} else {
  log('設計レビューにブロッカーなし。修正は行わない。')
}

log(`設計レビュー完了: blockers=${blockers.length}, revised=${revision !== null}`)

return {
  design_doc: designDoc,
  reviews,
  blockers,
  suggestions,
  revision,
}
