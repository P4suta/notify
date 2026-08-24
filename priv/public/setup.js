const form = document.querySelector('#setup-form');
const status = document.querySelector('#setup-status');
const token = new URL(location.href).searchParams.get('token');

if (!token) {
  form.hidden = true;
  status.textContent = 'This setup URL is incomplete. / setup token がありません。';
}

form?.addEventListener('submit', async (event) => {
  event.preventDefault();
  status.textContent = 'Creating administrator… / 作成中…';
  const values = new FormData(form);
  const response = await fetch('/api/v1/setup', {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify({
      token,
      username: values.get('username'),
      password: values.get('password'),
      anonymous_access: values.get('anonymous_access'),
    }),
  });
  const body = await response.json().catch(() => ({}));
  if (response.ok) {
    status.textContent = 'Setup complete. Redirecting… / 設定が完了しました。';
    location.replace('/');
  } else {
    status.textContent = body.detail || body.error || 'Setup failed / 設定に失敗しました';
  }
});
