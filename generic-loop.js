#!/usr/bin/env bun
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

/**
 * 通用迴圈範本
 * 在這裡替換 PROMPT 和 ALLOWED_TOOLS 來自訂行為
 */

// ============ 配置 ============
function extractPromptFromSource() {
  const source = readFileSync(new URL(import.meta.url), 'utf8');
  const startMarker = '/* ' + 'PROMPT_START\n';
  const endMarker = '\nPROMPT_END ' + '*/';
  const start = source.indexOf(startMarker);
  const end = source.indexOf(endMarker);

  if (start === -1 || end === -1 || end <= start) {
    throw new Error('PROMPT markers not found');
  }

  return source.slice(start + startMarker.length, end).trim();
}

const PROMPT = extractPromptFromSource();

/* PROMPT_START
You are an autonomous Senior Linux C++ Developer Agent. Your objective is to implement the requested features with production-level quality, adhering strictly to C++ best practices and Linux system standards.

You will manage your workflow using a strict task loop, relying on `SPEC.md` for requirements and `TODO.md` for state management. 

### INSTRUCTIONS & WORKFLOW LOOP:

Please execute the following loop systematically. Do not skip steps.

**Phase 1: Initialization**
1. **Read Specifications:** Read `SPEC.md` carefully to understand the complete scope of the feature.
2. **Initialize State:** Read `TODO.md`. If `TODO.md` does not exist or is empty, break down the requirements from `SPEC.md` into granular, sequential tasks and write them to `TODO.md` using standard markdown checkboxes (`- [ ] Task name`).

**Phase 2: The Execution Loop**
Repeat the following steps for each pending task until `TODO.md` is completely finished:
1. **Select:** Identify the first uncompleted task (`- [ ]`) in `TODO.md`.
2. **Implement:** Write or modify the necessary C++ code to complete the specific task. Keep your focus narrow and only implement what is required for this single step.
3. **Verify (Lint & Build):** Ensure your C++ code is syntactically correct, memory-safe, and adheres to standard linting rules (e.g., `clang-format`, `clang-tidy`). If there are errors, fix them before proceeding.
4. **Update State:** Update `TODO.md` by marking the completed task with an `x` (`- [x] Task name`).
5. **Report:** Briefly output the status of the completed task and announce the next task in the loop.

**Phase 3: Termination**
1. Once every item in `TODO.md` is marked as `[x]`, perform a final review of the codebase against `SPEC.md` to ensure nothing was missed.
2. Ensure all final linting and checks pass.
3. When all jobs are absolutely finished and verified, print exactly `完成` on the very last line of your output, and halt execution.


PROMPT_END */

const ALLOWED_TOOLS = 'Read,Edit,Glob,Grep';
const MAX_ITERATIONS = 100;  // 防止無限迴圈
const VERBOSE = true;

// ============ 執行 ============

let iteration = 0;

console.log('🚀 通用迴圈開始\n');
console.log(`配置: MAX_ITERATIONS=${MAX_ITERATIONS}, VERBOSE=${VERBOSE}\n`);

while (iteration < MAX_ITERATIONS) {
  iteration++;

  const timestamp = new Date().toLocaleString('zh-TW');
  console.log(`[${ timestamp}] 迭代 #${iteration}\n`);

  const result = spawnSync(
    'codex',
    [
      'exec'
    ],
    {
      cwd: import.meta.dirname,
      encoding: 'utf8',
      input: PROMPT,
      maxBuffer: 10 * 1024 * 1024
    }
  );

  const output = result.stdout ?? '';
  const err = result.stderr ?? '';

  if (err) {
    console.error('❌ 錯誤:', err.slice(0, 300));
  }

  if (VERBOSE && output.length > 0) {
    console.log(output.slice(-500));
  } else if (output.length > 0) {
    console.log(output.slice(-200));
  }

  console.log('');

  // 檢查完成條件
  if (output.includes('完成')) {
    console.log(`✅ 任務在迭代 #${iteration} 完成！\n`);
    break;
  }

  // 還有剩餘迭代次數
  if (iteration < MAX_ITERATIONS) {
    console.log(`⏳ 繼續執行... (${MAX_ITERATIONS - iteration} 次剩餘)\n`);
  }
}

if (iteration >= MAX_ITERATIONS) {
  console.log(`\n⚠️  達到最大迭代次數 (${MAX_ITERATIONS})，停止執行\n`);
}

console.log('='.repeat(50));
console.log(`總共執行: ${iteration} 次迭代`);
console.log('='.repeat(50));
