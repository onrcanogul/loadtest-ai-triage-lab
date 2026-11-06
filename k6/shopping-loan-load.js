// k6 load scenario for the shopping-loan API.
// Only purpose in this lab: generate traffic so the service fails in two different ways.
// The service and the triage know nothing about k6 (no run id, no test header).
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 20 },  // 0 -> 20 VU
    { duration: '60s', target: 80 },  // 20 -> 80 VU
    { duration: '60s', target: 80 },  // hold 80 VU
    { duration: '20s', target: 0 },   // ramp down
  ],
  thresholds: {
    // abortOnFail: once the error rate is above 5% the run is aborted ("test blew up, cannot continue").
    // delayAbortEval is 120s (not 30s) so that the ramp to 80 VU completes before the abort fires;
    // otherwise the ~5% background NPE errors alone would abort the run at 20 VU, before the
    // load-dependent scoring-pool exhaustion ever shows up. See README.
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '120s' }],
    http_req_duration: ['p(95)<800'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const CAMPAIGNS = ['POS2025', 'SUMMER10', 'BLACKFRIDAY'];
const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const randomInt = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

export default function () {
  // 90% valid requests with a campaign code, 10% without one and with 9 or 12 installments (triggers the NPE bug).
  const withCampaign = Math.random() < 0.9;
  const body = {
    customerId: `C${randomInt(100000, 999999)}`,
    amount: randomInt(1000, 50000),
    installmentCount: withCampaign ? pick([3, 6, 9, 12]) : pick([9, 12]),
  };
  if (withCampaign) {
    body.campaignCode = pick(CAMPAIGNS);
  }

  const apply = http.post(`${BASE_URL}/api/v1/loans/shopping/apply`, JSON.stringify(body),
    { ...JSON_HEADERS, tags: { name: 'POST /api/v1/loans/shopping/apply' } });
  check(apply, { 'apply -> 201': (r) => r.status === 201 });

  if (apply.status === 201) {
    const id = apply.json('applicationId');
    const get = http.get(`${BASE_URL}/api/v1/loans/${id}`, { tags: { name: 'GET /api/v1/loans/{applicationId}' } });
    check(get, { 'get -> 200': (r) => r.status === 200 });
  }

  sleep(0.3);
}
