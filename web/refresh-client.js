const repository = 'Sager1145/live-dashboard';
const workflow = 'pages-catalog.yml';
export const workflowURL = `https://github.com/${repository}/actions/workflows/${workflow}`;

export async function dispatchRefresh(token, request = fetch) {
  let response;
  try {
    response = await request(`https://api.github.com/repos/${repository}/actions/workflows/${workflow}/dispatches`, {
      method: 'POST',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${token}`,
        'X-GitHub-Api-Version': '2026-03-10',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ref: 'main' }),
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
    });
  } catch {
    throw new Error('无法连接 GitHub，请稍后重试。');
  }
  if (response.status === 200 || response.status === 204) return;
  if (response.status === 401 || response.status === 403) {
    throw new Error('凭据无效或没有此仓库的 Actions 读写权限。');
  }
  if (response.status === 404) {
    throw new Error('更新流程尚未部署，或凭据没有此仓库的访问权限。');
  }
  throw new Error(`GitHub 未接受更新请求（${response.status}），请在 Actions 检查流程。`);
}
