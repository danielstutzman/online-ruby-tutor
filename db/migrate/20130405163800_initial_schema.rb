class InitialSchema < ActiveRecord::Migration
  def up
    create_table :users do |t|
      t.string :first_name,          :limit => 30, :null => false
      t.string :last_name,           :limit => 30, :null => false
      t.string :email,               :limit => 90, :null => false
      t.string :google_plus_user_id, :limit => 30, :null => false
      t.timestamps
    end
    create_table :saves do |t|
      t.integer :user_id,      :null => false
      t.string  :exercise_num, :null => false
      t.boolean :is_current,   :null => false
      t.text    :code,         :null => false
      t.timestamps
    end
  end

  def down
    drop_table :users
    drop_table :saves
  end
end
