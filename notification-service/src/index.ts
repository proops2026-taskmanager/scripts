import 'dotenv/config';
import app from './app';
import { startConsumer } from './consumer';

const PORT = process.env.PORT ?? 3003;

app.listen(PORT, () => {
  console.log(`notification-service listening on port ${PORT}`);
});

// Start Redis Stream consumer in the background
startConsumer().catch((err) => {
  console.error('[consumer] Fatal error — exiting:', err);
  process.exit(1);
});
