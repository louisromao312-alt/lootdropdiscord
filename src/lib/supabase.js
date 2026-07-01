const { createClient } = require('@supabase/supabase-js');

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_KEY;

if (!supabaseUrl || !supabaseKey) {
  throw new Error('SUPABASE_URL und SUPABASE_KEY müssen in der .env gesetzt sein.');
}

/**
 * Supabase-Client für serverseitige Bot-Operationen.
 * Parameterisierte Queries verhindern SQL-Injection – niemals Raw-SQL verwenden.
 */
const supabase = createClient(supabaseUrl, supabaseKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
  },
});

module.exports = supabase;
