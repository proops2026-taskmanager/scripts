import request from 'supertest';
import { readFileSync } from 'fs';
import { join } from 'path';
import pool from '../db';
import app from '../app';
import { storeNotifications, parseFields } from '../consumer';

const USER_A = '11111111-1111-1111-1111-111111111111';
const USER_B = '22222222-2222-2222-2222-222222222222';
const TASK_ID = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

beforeAll(async () => {
  await pool.query('DROP TABLE IF EXISTS notifications CASCADE');
  const migration = readFileSync(
    join(__dirname, '../../db/migrations/001_create_notifications.sql'),
    'utf8'
  );
  await pool.query(migration);
});

beforeEach(async () => {
  await pool.query('TRUNCATE TABLE notifications RESTART IDENTITY CASCADE');
});

afterAll(async () => {
  await pool.end();
});

// ---------------------------------------------------------------------------

describe('GET /health', () => {
  it('200 — returns status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok', service: 'notification-service' });
  });
});

// ---------------------------------------------------------------------------

describe('parseFields', () => {
  it('converts flat string array to object', () => {
    const result = parseFields(['event', 'task.created', 'task_id', TASK_ID]);
    expect(result).toEqual({ event: 'task.created', task_id: TASK_ID });
  });
});

// ---------------------------------------------------------------------------

describe('storeNotifications', () => {
  it('stores one notification per recipient (actor + assignee)', async () => {
    await storeNotifications({
      event: 'task.created',
      task_id: TASK_ID,
      task_title: 'Fix login',
      actor_id: USER_A,
      assignee_id: USER_B,
    });

    const res = await pool.query('SELECT * FROM notifications ORDER BY created_at');
    expect(res.rows).toHaveLength(2);
    expect(res.rows.map((r: { user_id: string }) => r.user_id)).toEqual(
      expect.arrayContaining([USER_A, USER_B])
    );
  });

  it('stores one notification when actor and assignee are the same', async () => {
    await storeNotifications({
      event: 'task.created',
      task_id: TASK_ID,
      task_title: 'Self-assigned',
      actor_id: USER_A,
      assignee_id: USER_A,
    });

    const res = await pool.query('SELECT * FROM notifications');
    expect(res.rows).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------

describe('GET /notifications', () => {
  beforeEach(async () => {
    await storeNotifications({
      event: 'task.created',
      task_id: TASK_ID,
      task_title: 'Sprint task',
      actor_id: USER_A,
      assignee_id: USER_B,
    });
  });

  it('200 — returns own notifications with unread_count', async () => {
    const res = await request(app)
      .get('/notifications')
      .set('X-User-Id', USER_A);

    expect(res.status).toBe(200);
    expect(res.body.notifications).toHaveLength(1);
    expect(res.body.unread_count).toBe(1);
    expect(res.body.notifications[0].read).toBe(false);
    expect(res.body.notifications[0].body).toContain('Sprint task');
  });

  it('200 — does not return other users notifications', async () => {
    const res = await request(app)
      .get('/notifications')
      .set('X-User-Id', '33333333-3333-3333-3333-333333333333');

    expect(res.status).toBe(200);
    expect(res.body.notifications).toHaveLength(0);
    expect(res.body.unread_count).toBe(0);
  });

  it('200 — ?unread=true returns only unread', async () => {
    // mark first notification as read
    const notifId = (await pool.query('SELECT id FROM notifications WHERE user_id = $1', [USER_A])).rows[0].id;
    await pool.query('UPDATE notifications SET read = TRUE WHERE id = $1', [notifId]);

    const res = await request(app)
      .get('/notifications?unread=true')
      .set('X-User-Id', USER_A);

    expect(res.status).toBe(200);
    expect(res.body.notifications).toHaveLength(0);
    expect(res.body.unread_count).toBe(0);
  });

  it('401 — missing X-User-Id', async () => {
    const res = await request(app).get('/notifications');
    expect(res.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------

describe('PATCH /notifications/:id/read', () => {
  it('200 — marks notification as read', async () => {
    await storeNotifications({
      event: 'task.status_updated',
      task_id: TASK_ID,
      task_title: 'Auth task',
      actor_id: USER_A,
      assignee_id: USER_A,
      old_status: 'TODO',
      new_status: 'IN_PROGRESS',
    });

    const notifId = (await pool.query('SELECT id FROM notifications WHERE user_id = $1', [USER_A])).rows[0].id;

    const res = await request(app)
      .patch(`/notifications/${notifId}/read`)
      .set('X-User-Id', USER_A);

    expect(res.status).toBe(200);
    expect(res.body.read).toBe(true);
  });

  it('404 — wrong user cannot mark another user notification as read', async () => {
    await storeNotifications({
      event: 'comment.created',
      task_id: TASK_ID,
      task_title: 'Comment task',
      actor_id: USER_A,
      assignee_id: USER_A,
      comment_text: 'LGTM',
    });

    const notifId = (await pool.query('SELECT id FROM notifications WHERE user_id = $1', [USER_A])).rows[0].id;

    const res = await request(app)
      .patch(`/notifications/${notifId}/read`)
      .set('X-User-Id', USER_B);

    expect(res.status).toBe(404);
  });

  it('401 — missing X-User-Id', async () => {
    const res = await request(app).patch('/notifications/some-uuid/read');
    expect(res.status).toBe(401);
  });
});

// ---------------------------------------------------------------------------

describe('PATCH /notifications/read-all', () => {
  it('200 — marks all unread as read', async () => {
    await storeNotifications({ event: 'task.created', task_id: TASK_ID, task_title: 'T1', actor_id: USER_A, assignee_id: USER_A });
    await storeNotifications({ event: 'task.created', task_id: TASK_ID, task_title: 'T2', actor_id: USER_A, assignee_id: USER_A });

    const res = await request(app)
      .patch('/notifications/read-all')
      .set('X-User-Id', USER_A);

    expect(res.status).toBe(200);
    expect(res.body.updated).toBe(2);

    const check = await request(app).get('/notifications').set('X-User-Id', USER_A);
    expect(check.body.unread_count).toBe(0);
  });
});
