import axios from 'axios';

const WEBHOOK_URL = process.env.DISCORD_WEBHOOK_URL ?? '';

const STATUS_LABELS: Record<string, string> = {
  TODO:        'To Do',
  IN_PROGRESS: 'In Progress',
  DONE:        'Done',
  CANCELLED:   'Cancelled',
};

// Discord embed color per destination status
const STATUS_COLORS: Record<string, number> = {
  IN_PROGRESS: 0xFF8B00,
  DONE:        0x61BD4F,
  CANCELLED:   0x97A0AF,
};

interface EmbedField { name: string; value: string; inline?: boolean }

interface Embed {
  title: string;
  description?: string;
  color: number;
  fields?: EmbedField[];
  timestamp: string;
}

export function buildEmbed(fields: Record<string, string>): Embed | null {
  const { event, task_title, actor_id, assignee_id, old_status, new_status, comment_text, due_date } = fields;
  const timestamp = new Date().toISOString();

  switch (event) {
    case 'task.created': {
      const embedFields: EmbedField[] = [
        { name: 'Assigned to', value: assignee_id, inline: true },
        { name: 'Created by',  value: actor_id,    inline: true },
      ];
      if (due_date) {
        embedFields.push({
          name:   'Due',
          value:  new Date(due_date).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }),
          inline: true,
        });
      }
      return { title: '📋 New Task Created', description: `**${task_title}**`, color: 0x0079BF, fields: embedFields, timestamp };
    }

    case 'task.status_updated':
      return {
        title:       '🔄 Status Changed',
        description: `**${task_title}**`,
        color:       STATUS_COLORS[new_status] ?? 0x0079BF,
        fields: [
          { name: 'From',       value: STATUS_LABELS[old_status] ?? old_status, inline: true },
          { name: 'To',         value: STATUS_LABELS[new_status] ?? new_status, inline: true },
          { name: 'Changed by', value: actor_id,                                inline: true },
        ],
        timestamp,
      };

    case 'comment.created':
      return {
        title:       '💬 New Comment',
        description: `**${task_title}**\n> ${comment_text}`,
        color:       0x9B59B6,
        fields:      [{ name: 'By', value: actor_id, inline: true }],
        timestamp,
      };

    default:
      return null;
  }
}

export async function sendToDiscord(embed: Embed): Promise<void> {
  if (!WEBHOOK_URL) {
    console.warn('[discord] DISCORD_WEBHOOK_URL not set — skipping');
    return;
  }

  try {
    await axios.post(WEBHOOK_URL, { embeds: [embed] });
    console.log('[discord] Sent:', embed.title);
  } catch (err: unknown) {
    const status = (err as { response?: { status: number } }).response?.status;
    console.error('[discord] Failed:', status ?? (err as Error).message);
  }
}
