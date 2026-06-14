import Redis from 'ioredis';
import { buildEmbed, sendToDiscord } from './discord';
import pool from './db';

const STREAM   = 'task:events';
const GROUP    = 'notification-service';
const CONSUMER = 'notifier-1';

export function parseFields(raw: string[]): Record<string, string> {
  const obj: Record<string, string> = {};
  for (let i = 0; i < raw.length; i += 2) obj[raw[i]] = raw[i + 1];
  return obj;
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function buildBody(fields: Record<string, string>): string {
  switch (fields.event) {
    case 'task.created':
      return `New task created: "${fields.task_title}"`;
    case 'task.status_updated':
      return `Task "${fields.task_title}" moved from ${fields.old_status} → ${fields.new_status}`;
    case 'comment.created':
      return `New comment on "${fields.task_title}": ${fields.comment_text}`;
    default:
      return `Event: ${fields.event}`;
  }
}

// Determines which user IDs should receive the notification
function recipientIds(fields: Record<string, string>): string[] {
  const ids = new Set<string>();
  if (fields.actor_id) ids.add(fields.actor_id);
  if (fields.assignee_id) ids.add(fields.assignee_id);
  return [...ids];
}

export async function storeNotifications(fields: Record<string, string>): Promise<void> {
  const body = buildBody(fields);
  const recipients = recipientIds(fields);

  for (const userId of recipients) {
    await pool.query(
      `INSERT INTO notifications (user_id, event_type, task_id, task_title, body)
       VALUES ($1, $2, $3, $4, $5)`,
      [userId, fields.event, fields.task_id ?? null, fields.task_title ?? null, body],
    );
  }
}

export async function startConsumer(): Promise<void> {
  const redis = new Redis(process.env.REDIS_URL ?? 'redis://localhost:6379');

  redis.on('error', (err) => console.error('[consumer] Redis error:', err.message));

  // Create consumer group — idempotent (MKSTREAM creates the stream if absent)
  await redis
    .xgroup('CREATE', STREAM, GROUP, '$', 'MKSTREAM')
    .catch(() => { /* group already exists */ });

  console.log(`[consumer] Listening on stream "${STREAM}" as group "${GROUP}"`);

  while (true) {
    try {
      // BLOCK 5 seconds waiting for new messages; returns null on timeout
      const results = (await redis.xreadgroup(
        'GROUP', GROUP, CONSUMER,
        'COUNT', '10',
        'BLOCK', '5000',
        'STREAMS', STREAM, '>',
      )) as [string, [string, string[]][]][] | null;

      if (!results) continue;

      for (const [, messages] of results) {
        for (const [id, rawFields] of messages) {
          const fields = parseFields(rawFields);
          console.log('[consumer] Event:', fields.event, '| task:', fields.task_title);

          await Promise.allSettled([
            storeNotifications(fields),
            sendToDiscord(buildEmbed(fields)!).catch(() => {}),
          ]);

          // Acknowledge so the message is not re-delivered
          await redis.xack(STREAM, GROUP, id);
        }
      }
    } catch (err) {
      console.error('[consumer] Unexpected error:', err);
      await sleep(2000);
    }
  }
}
