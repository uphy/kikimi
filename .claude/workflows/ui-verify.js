export const meta = {
  name: 'kikimi-ui-verify',
  description: 'kikimi-verify skillでシナリオの動作確認を行い、失敗時はdiff分析→修正→再検証を最大2回繰り返す（kikimi.md 17.6準拠）',
  phases: [
    { title: 'UI Verify' },
    { title: 'Diagnose & Fix' },
    { title: 'Re-Verify' },
  ],
}

// args: { scenario: '録音開始→2ストリーム保存→書き起こしがUIに表示される、を確認する' }
// model 方針: UI 駆動・デバッグ修正が主体の機械的工程なので全 agent を sonnet 固定にする。

const REPO = '.'
const SPEC = 'kikimi.md'
const MAX_RETRIES = 2

const UI_VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    passed: { type: 'boolean' },
    screenshots: { type: 'array', items: { type: 'string' } },
    issues: { type: 'array', items: { type: 'string' } },
  },
  required: ['passed'],
}

const DIAGNOSIS_SCHEMA = {
  type: 'object',
  properties: {
    root_cause: { type: 'string' },
    fix_summary: { type: 'string' },
    changed_files: { type: 'array', items: { type: 'string' } },
  },
  required: ['root_cause', 'fix_summary'],
}

const scenario = args.scenario
if (!scenario) {
  throw new Error('args.scenario が必要です（確認したい動作の説明）')
}

function ctx() {
  return (
    `作業ディレクトリは ${REPO} （Kikimi リポジトリ）。仕様の単一真実は ${SPEC}（読み込み専用、変更しない）。` +
    `Kikimi 固有の運用ルールは ${REPO}/CLAUDE.md と ${REPO}/CLAUDE.local.md に書かれているので必ず読むこと。` +
    `コード・コメント・コミットメッセージは英語、会話向けの報告は日本語で書くこと。`
  )
}

phase('UI Verify')
log(`UI 動作確認シナリオ: ${scenario}`)
let verify = await agent(
  `${ctx()}\n\nkikimi-verify skill（~/.claude/skills/kikimi-verify/、SKILL.md 参照）を使って、以下の` +
    `シナリオの動作確認を行え:\n${scenario}\n` +
    `mise run apply でビルド・インストールし、SKILL.md の手順に沿ってキャプチャと verify_session.py の` +
    `両面で確認せよ。問題が見つかり原因が明白かつ軽微な場合はその場で修正してよいが、原因不明な場合は` +
    `無理に直さず issues に具体的に記録せよ。最終結果（PASS/FAIL・スクリーンショットまたはセッション` +
    `フォルダパス・残課題）を返せ。`,
  { schema: UI_VERIFY_SCHEMA, label: 'ui-verify:initial', model: 'sonnet' }
)

let attempt = 0
while (!verify.passed && attempt < MAX_RETRIES) {
  attempt += 1
  phase('Diagnose & Fix')
  log(`UI 動作確認 FAIL（${attempt}回目のリトライ）。diff 分析と修正を行う。`)
  const diagnosis = await agent(
    `${ctx()}\n\nシナリオ「${scenario}」の kikimi-verify 検証で以下の問題が見つかった:\n` +
      `${(verify.issues || []).join('\n')}\n` +
      `git diff・関連ソース・ログ（\`log stream --predicate 'subsystem == "io.github.uphy.Kikimi"' --level debug\`）` +
      `を確認して根本原因を分析し、修正を実装せよ。root_cause・fix_summary・変更したファイル一覧を返せ。`,
    { schema: DIAGNOSIS_SCHEMA, label: `diagnose-fix:attempt${attempt}`, model: 'sonnet' }
  )
  log(`修正内容: ${diagnosis.fix_summary}`)

  phase('Re-Verify')
  verify = await agent(
    `${ctx()}\n\n直前の修正（${diagnosis.fix_summary}）を踏まえ、kikimi-verify skill で` +
      `シナリオ「${scenario}」を再検証せよ。mise run apply で再ビルド・再インストールしてから確認すること。` +
      `最終結果を返せ。`,
    { schema: UI_VERIFY_SCHEMA, label: `ui-verify:retry${attempt}`, model: 'sonnet' }
  )
}

log(`UI 動作確認完了: passed=${verify.passed}, attempts=${attempt}`)

return {
  scenario,
  passed: verify.passed,
  attempts: attempt,
  final: verify,
}
