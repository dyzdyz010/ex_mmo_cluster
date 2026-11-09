import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = readFileSync(new URL("../../lib/auth_server_web/components/account_ui.js", import.meta.url), "utf8");

function passwordField() {
  // 组件测试只替换 DOM 运输面，执行真实网页脚本并观察提示和浏览器自定义校验状态。
  const input = new EventTarget();
  Object.assign(input, { value: "", minLength: 8, maxLength: -1, dataset: { maxlength: "20" }, validationMessage: "" });
  input.setCustomValidity = (message) => { input.validationMessage = message; };
  const hint = { dataset: { count: "password" }, textContent: "8–20 个字符" };
  const document = {
    querySelectorAll: (selector) => selector === "[data-count]" ? [hint] : [],
    querySelector: () => null,
    getElementById: () => input,
    addEventListener() {},
  };
  vm.runInNewContext(source, { document, window: { addEventListener() {} }, Intl });
  return { input, hint };
}

test("password hints enforce 8 to 20 Unicode graphemes and clear an oversized error", () => {
  const { input, hint } = passwordField();
  for (const [value, valid, length] of [
    ["123456789012345678901", false, 21], ["12345678901234567890", true, 20],
    ["1234567", false, 7], ["12345678", true, 8],
    ["😀".repeat(21), false, 21], ["😀".repeat(20), true, 20],
    ["e\u0301".repeat(20), true, 20],
  ]) {
    input.value = value;
    input.dispatchEvent(new Event("input"));
    assert.equal(hint.dataset.ok, String(valid));
    assert.equal(input.validationMessage === "", valid);
    assert.ok(hint.textContent.includes(String(length)));
  }
});
