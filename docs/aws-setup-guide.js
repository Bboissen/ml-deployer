(() => {
  'use strict';
  document.documentElement.classList.add('js');
  const checks = {tools: 'Managed tools', project: 'Project config', aws: 'AWS identity', github: 'GitHub access'};
  const labels = {Ready: '✓ Done', 'To do': '○ To do', 'Not checked': '… Not checked yet', Next: '→ Next', Waiting: '… Waiting'};
  const live = document.getElementById('live');
  let refreshing = false;

  function stepState(status, rows, step) {
    if (step in checks) {
      const row = rows[checks[step]];
      if (!row) return null;
      if (status.setup_mode === 'interactive' && row.state !== 'Ready') {
        const instructions = {tools: 'Tools are being prepared in the setup terminal.', project: 'Answer the project questions in the terminal running make. The file is saved automatically.', aws: 'Continue with the sign-in prompt in the setup terminal.', github: 'Continue with the repository access prompt in the setup terminal.'};
        return {...row, detail: instructions[step], next: null};
      }
      return row;
    }
    const last = rows['Last operation'];
    if (step === 'deploy') {
      if (status.deployed) return {state: 'Ready', detail: last ? last.detail : 'deployed'};
      if (last && last.state !== 'Ready') return last;
      if (status.ready) return {state: 'Next', detail: 'every check is ready: review and deploy', next: status.deploy};
      return {state: 'Waiting', detail: 'finish the steps above first'};
    }
    if (step === 'outputs') {
      if (status.deployed) return {state: 'Ready', detail: status.output_uri ? 'outputs at ' + status.output_uri : 'no declared outputs'};
      return {state: 'Waiting', detail: 'available after a successful Deploy'};
    }
    return null;
  }

  function element(tag, className, text) {
    const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node;
  }

  function notice(kind, text) { live.className = 'note ' + kind; live.replaceChildren(element('p', '', text)); }

  function show(status) {
    const rows = {};
    if (Array.isArray(status.rows)) for (const row of status.rows) rows[row.check] = row;
    let first = null;
    for (const li of document.querySelectorAll('li[data-step]')) {
      li.classList.remove('done', 'todo', 'pending'); li.querySelector('.state')?.remove();
      const s = stepState(status, rows, li.dataset.step); if (!s) continue;
      const done = s.state === 'Ready';
      li.classList.add(done ? 'done' : (s.state === 'To do' || s.state === 'Next') ? 'todo' : 'pending');
      if (!done && !first && (s.state === 'To do' || s.state === 'Next' || s.next)) first = li;
      const box = element('div', 'state');
      box.append(element('span', 'badge', labels[s.state] || s.state), element('span', '', s.detail || ''));
      li.querySelector('h3').insertAdjacentElement('afterend', box);
      if (s.next && !done) { const pre = element('pre'); pre.append(element('code', '', s.next)); box.append(pre); addCopy(pre); }
    }
    if (status.repository === 'public' || status.repository === 'private') { repo.value = status.repository; render(); }
    const when = new Date(status.checked_at);
    live.className = 'note ' + (first || !status.ready ? 'warn' : 'good');
    live.replaceChildren();
    const head = element('p'); head.append(element('strong', '', first ? 'Next: ' + first.querySelector('h3').textContent : status.ready ? (status.deployed ? 'Deployed.' : 'Ready to deploy.') : 'Readiness not confirmed.'));
    head.append(' Checked ' + (isNaN(when) ? 'just now' : when.toLocaleTimeString()) + ' for ' + (status.expected_config ? status.expected_config + ' (not created yet)' : status.config || 'no project file yet') + '.');
    live.append(head, element('p', 'meta', 'This page re-checks every 20 seconds and when you come back to it. It never logs in, deploys or changes cloud resources.'));
    if (first) {
      const action = stepState(status, rows, first.dataset.step);
      live.append(element('p', '', action.detail));
      if (action.next) { const pre = element('pre'); pre.append(element('code', '', action.next)); live.append(pre); addCopy(pre); }
    }
  }

  async function refresh() {
    if (location.protocol === 'file:' || refreshing) return;
    refreshing = true;
    try {
      const response = await fetch('status.json', {cache: 'no-store'});
      if (!response.ok) throw new Error('readiness unavailable');
      const status = await response.json();
      if (status.error) notice('warn', status.error); else show(status);
    } catch { notice('warn', 'Live readiness is unavailable. Check the guide terminal; if it stopped, run make again in the repository folder.'); }
    finally { refreshing = false; }
  }

  const repo = document.getElementById('repo'), pick = document.getElementById('pick'); const key = 'aws-workspace-guide-v3';
  try { const saved = localStorage.getItem(key); if (['public', 'private', 'all'].includes(saved)) repo.value = saved; } catch {}
  function render() {
    for (const el of document.querySelectorAll('.variant')) el.style.display = repo.value !== 'all' && el.dataset.repo !== repo.value ? 'none' : 'block';
  }
  pick.hidden = false;
  repo.addEventListener('change', () => { render(); try { localStorage.setItem(key, repo.value); } catch {} });
  function addCopy(pre) {
    const button = document.createElement('button'); button.type = 'button'; button.className = 'copy'; button.textContent = 'Copy commands';
    const result = document.createElement('span'); result.className = 'copied'; result.setAttribute('aria-live', 'polite');
    button.addEventListener('click', async () => {
      const text = pre.textContent;
      try { if (!navigator.clipboard) throw new Error('no clipboard'); await navigator.clipboard.writeText(text); result.textContent = 'Copied; run it in your terminal.'; }
      catch { try { const range = document.createRange(); range.selectNodeContents(pre); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range); result.textContent = 'Clipboard unavailable; the command is selected, copy it with your keyboard.'; }
             catch { result.textContent = 'Clipboard unavailable; select and copy the command text above.'; } }
    });
    pre.insertAdjacentElement('afterend', button); button.insertAdjacentElement('afterend', result);
  }
  for (const pre of document.querySelectorAll('pre')) addCopy(pre);
  render();
  refresh(); setInterval(() => { if (!document.hidden) refresh(); }, 20000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
  window.addEventListener('focus', refresh);
})();
