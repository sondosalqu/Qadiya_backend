import bcrypt from "bcryptjs";
import { prisma } from "../src/lib/prisma.js";

const [, , full_name, username, email, password, role = "investigator"] = process.argv;

if (!full_name || !username || !email || !password) {
  console.log('Usage: npx tsx scripts/create-user.ts "Full Name" username email password [admin|investigator]');
  process.exit(1);
}

const password_hash = await bcrypt.hash(password, 10);

const user = await prisma.users.create({
  data: { full_name, username, email: email.toLowerCase(), password_hash, role },
});

console.log(`✅ Created ${user.role}: ${user.username} (id ${user.user_id})`);
await prisma.$disconnect();