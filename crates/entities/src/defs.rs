#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct VarId(pub u16);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct UVarId(pub u16);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct RelationId(pub u16);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct SetId(pub u16);

/// The schema's vocabulary: which vars, relations and sets exist, by name.
/// Ids are assigned in definition order; stores size themselves from this
/// at construction, so define everything before building the world.
#[derive(Default, Clone)]
pub struct Definitions {
    var_names: Vec<String>,
    uvar_names: Vec<String>,
    relation_names: Vec<String>,
    set_names: Vec<String>,
}

impl Definitions {
    pub fn define_var(&mut self, name: impl Into<String>) -> VarId {
        let id = VarId(u16::try_from(self.var_names.len()).unwrap());
        self.var_names.push(name.into());
        id
    }

    pub fn define_uvar(&mut self, name: impl Into<String>) -> UVarId {
        let id = UVarId(u16::try_from(self.uvar_names.len()).unwrap());
        self.uvar_names.push(name.into());
        id
    }

    pub fn define_relation(&mut self, name: impl Into<String>) -> RelationId {
        let id = RelationId(u16::try_from(self.relation_names.len()).unwrap());
        self.relation_names.push(name.into());
        id
    }

    pub fn define_set(&mut self, name: impl Into<String>) -> SetId {
        let id = SetId(u16::try_from(self.set_names.len()).unwrap());
        self.set_names.push(name.into());
        // Membership lives in each entity's inline BitSet<1>: one bit per
        // set. Plenty for now; if it ever transpires, widen the BitSet.
        assert!(self.set_names.len() <= 64);
        id
    }

    pub fn get_var_name(&self, id: VarId) -> Option<&str> {
        self.var_names.get(id.0 as usize).map(String::as_str)
    }

    pub fn get_uvar_name(&self, id: UVarId) -> Option<&str> {
        self.uvar_names.get(id.0 as usize).map(String::as_str)
    }

    pub fn get_relation_name(&self, id: RelationId) -> Option<&str> {
        self.relation_names.get(id.0 as usize).map(String::as_str)
    }

    pub fn get_set_name(&self, id: SetId) -> Option<&str> {
        self.set_names.get(id.0 as usize).map(String::as_str)
    }

    pub fn iter_vars(&self) -> impl ExactSizeIterator<Item = VarId> {
        (0..self.var_names.len() as u16).map(VarId)
    }

    pub fn iter_uvars(&self) -> impl ExactSizeIterator<Item = UVarId> {
        (0..self.uvar_names.len() as u16).map(UVarId)
    }

    pub fn iter_relations(&self) -> impl ExactSizeIterator<Item = RelationId> {
        (0..self.relation_names.len() as u16).map(RelationId)
    }

    pub fn iter_sets(&self) -> impl ExactSizeIterator<Item = SetId> {
        (0..self.set_names.len() as u16).map(SetId)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn definitions_assign_names_and_iterate_ids() {
        let mut defs = Definitions::default();
        let x = defs.define_var("x");
        let age = defs.define_var("age");
        let married = defs.define_relation("married");
        let citizens = defs.define_set("citizens");

        assert_eq!(defs.get_var_name(x), Some("x"));
        assert_eq!(defs.get_var_name(age), Some("age"));
        assert_eq!(defs.get_relation_name(married), Some("married"));
        assert_eq!(defs.get_set_name(citizens), Some("citizens"));
        assert_eq!(defs.get_var_name(VarId(2)), None);
        assert_eq!(defs.iter_vars().collect::<Vec<_>>(), [x, age]);
        assert_eq!(defs.iter_relations().collect::<Vec<_>>(), [married]);
        assert_eq!(defs.iter_sets().collect::<Vec<_>>(), [citizens]);
    }
}
