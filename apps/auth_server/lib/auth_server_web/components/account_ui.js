// 全局系统功能：账号网页的渐进增强。页面在脚本缺失时仍可完整提交，这里只改善输入与反馈。
(() => {
  const all = (selector) => [...document.querySelectorAll(selector)];

  // 显示／隐藏密码。
  all("[data-reveal]").forEach((button) => {
    const input = document.getElementById(button.dataset.reveal);
    button.hidden = false;
    button.addEventListener("click", () => {
      const show = input.type === "password";
      input.type = show ? "text" : "password";
      button.textContent = show ? "隐藏" : "显示";
      button.setAttribute("aria-pressed", String(show));
      input.focus();
    });
  });

  // 密码长度实时提示，与服务端 minlength 保持同一来源。
  all("[data-count]").forEach((hint) => {
    const input = document.getElementById(hint.dataset.count);
    const min = input.minLength;
    const update = () => {
      const n = [...input.value].length;
      hint.dataset.ok = String(n >= min);
      hint.textContent = n === 0 ? hint.dataset.idle : n < min ? `已输入 ${n} 个字符，还差 ${min - n} 个` : `已输入 ${n} 个字符 · 长度符合要求`;
    };
    hint.dataset.idle = hint.textContent;
    input.addEventListener("input", update);
    update();
  });

  // 危险操作二次确认：第一次点击只改为确认文字，4 秒内再次点击才提交。
  all("[data-confirm]").forEach((button) => {
    const label = button.textContent;
    let timer;
    button.addEventListener("click", (event) => {
      if (button.classList.contains("is-armed")) return;
      event.preventDefault();
      button.classList.add("is-armed");
      button.textContent = button.dataset.confirm;
      timer = setTimeout(() => {
        button.classList.remove("is-armed");
        button.textContent = label;
      }, 4000);
    });
    button.form?.addEventListener("submit", () => clearTimeout(timer));
  });

  // 防止重复提交，并给出处理中状态。
  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (form.dataset.busy) return event.preventDefault();
    form.dataset.busy = "1";
    event.submitter?.classList.add("is-busy");
    event.submitter?.setAttribute("aria-busy", "true");
  });
  window.addEventListener("pageshow", () => {
    all("form[data-busy]").forEach((form) => delete form.dataset.busy);
    all(".is-busy").forEach((button) => { button.classList.remove("is-busy"); button.removeAttribute("aria-busy"); });
  });

  // 邮件发送后的重发冷却，与服务端每邮箱 60 秒一封的限制一致。
  all("[data-cooldown]").forEach((button) => {
    const label = button.textContent;
    let left = Number(button.dataset.cooldown);
    const tick = () => {
      if (left <= 0) { button.disabled = false; button.textContent = label; return; }
      button.disabled = true;
      button.textContent = `${label}（${left} 秒）`;
      left -= 1;
      setTimeout(tick, 1000);
    };
    tick();
  });

  // 邮件链接把邮箱和验证码放在 # 片段中（不发往服务器、不进日志），这里填入表单后立即清除。
  const prefill = document.querySelector("[data-prefill]");
  if (prefill && location.hash.length > 1) {
    const params = new URLSearchParams(location.hash.slice(1));
    ["email", "code"].forEach((name) => {
      const input = prefill.querySelector(`[name="${name}"]`);
      if (input && params.get(name)) input.value = params.get(name);
    });
    history.replaceState(null, "", location.pathname + location.search);
    [...prefill.querySelectorAll("input:not([type=hidden])")].find((input) => !input.value)?.focus();
  }

  // 时间按浏览器所在时区显示，原始 UTC 保留在 title。
  const format = new Intl.DateTimeFormat("zh-CN", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false });
  all("time[datetime]").forEach((time) => {
    const date = new Date(time.dateTime);
    if (!Number.isNaN(date.getTime())) { time.title = time.textContent; time.textContent = format.format(date); }
  });

  // 复制邀请码。
  all("[data-copy]").forEach((button) => {
    const label = button.textContent;
    button.hidden = false;
    button.addEventListener("click", async () => {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = "已复制";
      setTimeout(() => { button.textContent = label; }, 1600);
    });
  });
})();
