import { dispatchRefresh, workflowURL } from './refresh-client.js';

const form = document.querySelector('#refresh-form');
const tokenInput = document.querySelector('#token');
const button = document.querySelector('#submit');
const status = document.querySelector('#status');
const runs = document.querySelector('#runs');
runs.href = workflowURL;

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const token = tokenInput.value.trim();
  if (!token) return;
  tokenInput.value = '';
  button.disabled = true;
  status.textContent = '正在请求更新…';
  try {
    await dispatchRefresh(token);
    status.textContent = '更新请求已提交。采集完成后会自动发布，iOS 会在下次同步时读取。';
  } catch (error) {
    status.textContent = error.message;
  } finally {
    button.disabled = false;
  }
});
