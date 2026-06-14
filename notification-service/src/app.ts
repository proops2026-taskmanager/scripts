import express, { Request, Response } from 'express';
import morgan from 'morgan';
import pool from './db';

const app = express();

app.use(express.json());
app.use(morgan('combined'));

app.get('/health', (_req, res) => {
  res.status(200).json({ status: 'ok', service: 'notification-service' });
});

// GET /notifications — list notifications for the authenticated user
// api-gateway injects X-User-Id after JWT validation
app.get('/notifications', async (req: Request, res: Response): Promise<void> => {
  const userId = req.headers['x-user-id'] as string | undefined;
  if (!userId) { res.status(401).json({ error: 'unauthorized' }); return; }

  const unreadOnly = req.query.unread === 'true';
  const limit = Math.min(Number(req.query.limit ?? 50), 100);

  try {
    const where = unreadOnly ? 'WHERE user_id = $1 AND read = FALSE' : 'WHERE user_id = $1';
    const result = await pool.query(
      `SELECT id, event_type, task_id, task_title, body, read, created_at
       FROM notifications ${where} ORDER BY created_at DESC LIMIT $2`,
      [userId, limit],
    );

    const unreadCount = await pool.query(
      'SELECT COUNT(*) FROM notifications WHERE user_id = $1 AND read = FALSE',
      [userId],
    );

    res.json({
      notifications: result.rows,
      unread_count: parseInt(unreadCount.rows[0].count, 10),
    });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// PATCH /notifications/:id/read — mark a notification as read
app.patch('/notifications/:id/read', async (req: Request, res: Response): Promise<void> => {
  const userId = req.headers['x-user-id'] as string | undefined;
  if (!userId) { res.status(401).json({ error: 'unauthorized' }); return; }

  try {
    const result = await pool.query(
      `UPDATE notifications SET read = TRUE
       WHERE id = $1 AND user_id = $2
       RETURNING id, read`,
      [req.params.id, userId],
    );

    if (!result.rows.length) {
      res.status(404).json({ error: 'notification not found' });
      return;
    }

    res.json(result.rows[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// PATCH /notifications/read-all — mark all unread notifications as read
app.patch('/notifications/read-all', async (req: Request, res: Response): Promise<void> => {
  const userId = req.headers['x-user-id'] as string | undefined;
  if (!userId) { res.status(401).json({ error: 'unauthorized' }); return; }

  try {
    const result = await pool.query(
      'UPDATE notifications SET read = TRUE WHERE user_id = $1 AND read = FALSE',
      [userId],
    );
    res.json({ updated: result.rowCount });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

export default app;
