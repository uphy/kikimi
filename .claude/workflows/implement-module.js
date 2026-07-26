export const meta = {
  name: 'kikimi-implement-module',
  description: 'モジュール群を「実装→セルフレビュー→単体テスト作成・実行」のpipelineで実装し、失敗分だけ修正する（kikimi.md 17.6準拠）',
  phases: [
    { title: 'Module Planning' },
    { title: 'Implement' },
    { title: 'Fix Failures' },
  ],
}

// args: { modules: [{ name, spec, files }] }
// または args: { feature: 'audio-capture', design_doc: 'docs/design/01-audio-capture.md' }（省略時は設計文書名から推測）
// model 方針: 実装・セルフレビュー・テスト・修正の機械的工程は sonnet 固定。
// Module Planning（分割判断が下流全体を左右する）だけはセッションモデルを継承する。

const REPO = '.'
const SPEC = 'kikimi.md'
// pipeline() は複数モジュールの実装/セルフレビュー/テストの各段階を重ねて並行に進める
// （あるモジュールがテスト段階にいる間、別モジュールが実装段階を進める、という古典的なパイプライン並行性）。
// このリポジトリは単一の Swift Package（.build を共有）なので、複数モジュールが同時に
// `swift build`/`swift test` を叩くと .build のロック競合でハングし、Workflow 全体が
// stall 判定で失敗する（phase-cycle.js の judgment log 参照）。この Workflow はテスト作成・実行を
// pipeline のステージに含める設計を明示的に要求されているため、テスト段階のプロンプトに
// 「ロックファイルで排他制御してから build/test を実行する」ことを明記して回避する。
const BUILD_LOCK = '/tmp/kikimi-workflow-swift-build.lock'

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

function ctx() {
  return (
    `作業ディレクトリは ${REPO} （Kikimi リポジトリ）。仕様の単一真実は ${SPEC}（読み込み専用、変更しない）。` +
    `Kikimi 固有の運用ルールは ${REPO}/CLAUDE.md と ${REPO}/CLAUDE.local.md に書かれているので必ず読むこと。` +
    `Chirami 参照実装のマップは ${REPO}/docs/references/chirami-map.md にある。` +
    `Chirami（ローカル参照リポジトリ。場所は CLAUDE.local.md 参照）のコードは read-only 参照専用。絶対に変更しない。` +
    `コード・コメント・コミットメッセージは英語、会話向けの報告は日本語で書くこと。`
  )
}

function buildLockInstruction() {
  return (
    `**重要（並行実行対策）**: 他のモジュールと \`swift build\`/\`swift test\` が同時実行されないよう、` +
    `実行前にロックファイル \`${BUILD_LOCK}\` を排他的に確保すること` +
    `（例: \`while ! mkdir ${BUILD_LOCK} 2>/dev/null; do sleep 2; done\` で確保する）。` +
    `build/test の完了後（失敗時も含めて）は必ず \`rmdir ${BUILD_LOCK}\` で解放すること。解放を忘れると` +
    `他モジュールの検証がハングする。`
  )
}

let moduleList
if (Array.isArray(args.modules) && args.modules.length > 0) {
  moduleList = { modules: args.modules }
  log(`引数で指定されたモジュール数: ${moduleList.modules.length}`)
} else {
  phase('Module Planning')
  const feature = args.feature
  if (!feature) {
    throw new Error('args.modules（モジュール配列）または args.feature（機能名）のいずれかが必要です')
  }
  const designDoc = args.design_doc || `docs/design/${feature}.md`
  log(`feature=${feature} からモジュール分割を行う（design_doc=${designDoc}）`)
  moduleList = await agent(
    `${ctx()}\n\n${REPO}/${designDoc} が存在すれば読み、無ければ機能「${feature}」の説明とリポジトリの` +
      `既存構造から、実装すべきモジュール（Swift ファイル単位程度の粒度）をリストアップせよ。各モジュールに` +
      `name・実装すべき内容の spec・関連ファイルパスを含めること。`,
    { schema: MODULE_LIST_SCHEMA, label: `modules:${feature}` }
  )
  log(`モジュール分割完了: ${moduleList.modules.length} 件`)
}

phase('Implement')
const results = await pipeline(
  moduleList.modules,
  (m) =>
    agent(
      `${ctx()}\n\nモジュール「${m.name}」を実装せよ。\n仕様:\n${m.spec}\n` +
        `関連ファイル: ${(m.files || []).join(', ')}\n実装後、変更したファイル一覧を報告せよ。`,
      { label: `impl:${m.name}`, model: 'sonnet' }
    ),
  (impl, m) =>
    agent(
      `${ctx()}\n\n直前に実装されたモジュール「${m.name}」（実装報告: ${String(impl).slice(0, 2000)}）を` +
        `コードリーディングでセルフレビューせよ。バグ・仕様との齟齬・簡略化できる箇所を指摘し、軽微なものは` +
        `その場で修正せよ。`,
      { label: `selfreview:${m.name}`, model: 'sonnet' }
    ),
  (_selfreview, m) =>
    agent(
      `${ctx()}\n\nモジュール「${m.name}」について、${REPO}/KikimiTests/ に不足している単体テスト` +
        `（swift-testing）を作成せよ。${buildLockInstruction()}\n` +
        `ロック確保後 \`swift build\` → \`swift test\` を実行して結果を確認し、ロックを解放してから` +
        `最終結果（passed/failures）を返せ。`,
      { schema: TEST_RESULT_SCHEMA, label: `test:${m.name}`, model: 'sonnet' }
    )
)

const failing = moduleList.modules
  .map((m, i) => ({ module: m, index: i, result: results[i] }))
  .filter((r) => r.result && r.result.passed === false)

if (failing.length > 0) {
  phase('Fix Failures')
  log(`テスト失敗モジュール: ${failing.length} 件。失敗分だけ修正する。`)
  const fixes = await parallel(
    failing.map(
      ({ module: m, result: r }) =>
        () =>
          agent(
            `${ctx()}\n\nモジュール「${m.name}」の単体テストが失敗した:\n${(r.failures || []).join('\n')}\n` +
              `原因を調査して実装またはテストを修正せよ。${buildLockInstruction()}\n` +
              `ロック確保後 \`swift build\` → \`swift test\` を再実行して通ることを確認し、ロックを解放してから` +
              `最終結果を返せ。`,
            { schema: TEST_RESULT_SCHEMA, label: `fix:${m.name}`, model: 'sonnet' }
          )
    )
  )
  failing.forEach((f, i) => {
    results[f.index] = fixes[i]
  })
} else {
  log('全モジュールの単体テストが通過。修正不要。')
}

log(`Implement 完了: モジュール数=${moduleList.modules.length}, 失敗修正=${failing.length}`)

return {
  modules: moduleList.modules,
  results,
}
